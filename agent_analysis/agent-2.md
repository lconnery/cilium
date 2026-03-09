# RCA: `TestConformance/BackendTLSPolicyInvalidCACertificateRef`

## Executive RCA

The flake is a timing race between (a) when Cilium/Envoy enters the "TLS-origination waiting on SDS secret" state and (b) the conformance test's fixed 30s convergence deadline. Cilium validates both bad policies correctly (`Accepted=False`, `ResolvedRefs=False`), but the data-plane translation still programs backend TLS/SDS references from `BackendTLSPolicy` refs while `secretsync` refuses to create SDS secrets unless policy is `Accepted=True`. Envoy then waits ~30s for SDS initial fetch to time out before returning a definitive TLS failure (`503` with `Secret is not supplied by SDS`). In failing runs, the first subtest (`nonexistent-ca`) times out a few hundred ms before that transition and only sees `404/400`; the second subtest (`malformed-ca`) starts immediately after and catches the post-timeout `503`, so it passes.

---

## Scope and Inputs Reviewed

Primary evidence came from:

- `example_failure_data/run_56/*` (deep timeline reconstruction)
- `example_failure_data/run_2/*` (timing corroboration)
- `example_failure_data/run_107/*` (same failure shape corroboration)
- Cilium control-plane/data-plane code paths:
  - `operator/pkg/gateway-api/gateway_reconcile.go`
  - `operator/pkg/gateway-api/helpers/backendtlspolicies.go`
  - `operator/pkg/model/ingestion/gateway.go`
  - `operator/pkg/model/translation/envoy_cluster_mutator.go`
  - `operator/pkg/gateway-api/policychecks/backendtlspolicy.go`
  - `operator/pkg/gateway-api/secretsync.go`
  - `operator/pkg/secretsync/configmapsync_reconcile.go`
- Gateway API conformance test and timeout utilities:
  - `vendor/sigs.k8s.io/gateway-api/conformance/tests/backendtlspolicy-invalid-ca-certificate-ref.go`
  - `vendor/sigs.k8s.io/gateway-api/conformance/tests/backendtlspolicy-invalid-ca-certificate-ref.yaml`
  - `vendor/sigs.k8s.io/gateway-api/conformance/utils/http/http.go`
  - `vendor/sigs.k8s.io/gateway-api/conformance/utils/config/timeout.go`

I did **not** run tests locally.

---

## Test Semantics (What must happen)

The conformance manifest creates two invalid `BackendTLSPolicy` cases:

```yaml
# vendor/.../backendtlspolicy-invalid-ca-certificate-ref.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: nonexistent-ca-certificate-ref
  namespace: gateway-conformance-infra
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: "backendtlspolicy-nonexistent-ca-certificate-ref-test"
  validation:
    caCertificateRefs:
      - group: ""
        kind: ConfigMap
        name: "nonexistent-ca-certificate"
    hostname: "abc.example.com"
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: malformed-ca-certificate-ref
  namespace: gateway-conformance-infra
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: "backendtlspolicy-malformed-ca-certificate-ref-test"
  validation:
    caCertificateRefs:
      - group: ""
        kind: ConfigMap
        name: "malformed-ca-certificate"
    hostname: "abc.example.com"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: malformed-ca-certificate
  namespace: gateway-conformance-infra
data: {}
```

The test executes in this fixed order (`nonexistent` first, then `malformed`) and expects HTTP `5xx`:

```go
// vendor/.../backendtlspolicy-invalid-ca-certificate-ref.go
for _, policyNN := range []types.NamespacedName{
    {Name: "nonexistent-ca-certificate-ref", Namespace: ns},
    {Name: "malformed-ca-certificate-ref", Namespace: ns},
} {
    t.Run("BackendTLSPolicy_"+policyNN.Name, func(t *testing.T) {
        // ... condition checks ...
        t.Run("HTTP Request to backend targeted by an invalid BackendTLSPolicy receive a 5xx", func(t *testing.T) {
            h.MakeRequestAndExpectEventuallyConsistentResponse(... StatusCodes: []int{500, 502, 503})
        })
    })
}
```

Convergence policy is fixed at 30s, with 3 consecutive successes required:

```go
// vendor/.../utils/config/timeout.go
MaxTimeToConsistency:         30 * time.Second,
RequiredConsecutiveSuccesses: 3,
```

```go
// vendor/.../utils/http/http.go
// Each failed attempt has a 1s delay.
func AwaitConvergence(..., threshold int, maxTimeToConsistency time.Duration, ...) {
    // ...
    delay := time.Second
    // timeout => fatal
}
```

---

## Cilium Behavior Path (Control Plane -> Envoy)

### 1) Gateway reconcile validates policy status, but ingestion still gets full policy map

```go
// operator/pkg/gateway-api/gateway_reconcile.go
btlspList := &gatewayv1.BackendTLSPolicyList{}
if err := r.Client.List(ctx, btlspList); err != nil { ... }
btlspMap := helpers.BuildBackendTLSPolicyLookup(btlspList)

if err := r.setBackendTLSPolicyStatuses(scopedLog, ctx, httpRoutes, btlspMap, req.NamespacedName); err != nil { ... }

httpListeners, tlsPassthroughListeners := ingestion.GatewayAPI(scopedLog, ingestion.Input{
    // ...
    BackendTLSPolicyMap: btlspMap,
})
```

### 2) Policy validation correctly marks invalid refs as rejected

```go
// operator/pkg/gateway-api/policychecks/backendtlspolicy.go
err := b.Client.Get(ctx, caCertRefKey, caCert)
if err != nil {
    if k8serrors.IsNotFound(err) {
        b.setRejectedConditions(... ReasonNoValidCACertificate, ... ReasonInvalidCACertificateRef)
        return false, nil
    }
    return false, err
}

if _, ok := caCert.Data["ca.crt"]; !ok {
    b.setRejectedConditions(... ReasonNoValidCACertificate, ... ReasonInvalidCACertificateRef)
    return false, nil
}
```

### 3) Ingestion applies backend TLS from `collection.Valid` without checking `Accepted`

```go
// operator/pkg/model/ingestion/gateway.go
if collection, ok := btlspMap[svcFullName]; ok {
    for sectionName, btlsp := range collection.Valid {
        // ...
        be.TLS = &model.BackendTLSOrigination{SNI: string(btlsp.Spec.Validation.Hostname)}
        if len(btlsp.Spec.Validation.CACertificateRefs) > 0 {
            be.TLS.CACertRef = &model.FullyQualifiedResource{
                Kind: "ConfigMap",
                Name: string(btlsp.Spec.Validation.CACertificateRefs[0].Name),
                Namespace: btlsp.GetNamespace(),
            }
        }
    }
}
```

`BuildBackendTLSPolicyLookup` "valid" means conflict-resolution winner, not spec-valid:

```go
// operator/pkg/gateway-api/helpers/backendtlspolicies.go
lookupMap[svcName].UpsertValidPolicy(sectionName, &currentBTLSP)
```

### 4) Envoy clusters are configured to fetch CA via SDS

```go
// operator/pkg/model/translation/envoy_cluster_mutator.go
ValidationContextSdsSecretConfig: &envoy_config_tls.SdsSecretConfig{
    Name: "cilium-secrets" + "/" + tls.CACertRef.Namespace + "-cfgmap-" + tls.CACertRef.Name,
},
```

### 5) Secret sync is gated on `Accepted=True`

```go
// operator/pkg/gateway-api/secretsync.go
for _, ancestorStatus := range btlsp.Status.Ancestors {
    if ancestorStatus.ControllerName == controllerName && helpers.IsAccepted(ancestorStatus.Conditions) {
        return true
    }
}
return false
```

```go
// operator/pkg/secretsync/configmapsync_reconcile.go
if reg.RefObjectCheckFunc(ctx, r.client, r.logger, original) {
    // sync secret
}
// else action remains ignored (no synced SDS secret)
```

This is the key control-plane mismatch: **data plane expects SDS secret; secret sync intentionally withholds it for rejected policy**.

---

## Evidence From Captures (Ordered Timeline)

## A) Policies are rejected as expected

`run_56/gwapi_capture_90_20260308_081529.yaml`:

```yaml
status:
  ancestors:
  - conditions:
    - message: CA Certificate ConfigMap does not contain a `ca.crt` key
      reason: NoValidCACertificate
      status: "False"
      type: Accepted
    - message: CA Certificate ConfigMap does not contain a `ca.crt` key
      reason: InvalidCACertificateRef
      status: "False"
      type: ResolvedRefs
...
status:
  ancestors:
  - conditions:
    - message: 'CA Certificate does not exist: gateway-conformance-infra/nonexistent-ca-certificate'
      reason: NoValidCACertificate
      status: "False"
      type: Accepted
    - message: 'CA Certificate does not exist: gateway-conformance-infra/nonexistent-ca-certificate'
      reason: InvalidCACertificateRef
      status: "False"
      type: ResolvedRefs
```

## B) Reconcile churn: first no policies, then policies present

`run_56/cilium-operator-85cfd5c96b-d6kcf.log`:

```text
08:15:28.148 ... Updating BackendTLSPolicy statuses ... policies=0
08:15:28.148 ... Checking Backend TLS Details ... backend ... TLS:<nil> ... nonexistent ...
08:15:28.148 ... Checking Backend TLS Details ... backend ... TLS:<nil> ... malformed ...
...
08:15:28.172 ... Updating BackendTLSPolicy statuses ... policies=2
08:15:28.172 ... Validating BackendTLSPolicy spec ... nonexistent-ca-certificate-ref
08:15:28.179 ... Validating BackendTLSPolicy spec ... malformed-ca-certificate-ref
```

## C) `secretsync` never provides SDS secret for either failing ref

Same operator log:

```text
08:15:28.153 ... Reconciling ConfigMap ... malformed-ca-certificate
08:15:28.153 ... Unable to get ConfigMap ... not found
08:15:28.153 ... Successfully reconciled ConfigMap ... action=ignored
08:15:28.160 ... Reconciling ConfigMap ... malformed-ca-certificate
08:15:28.160 ... Successfully reconciled ConfigMap ... action=ignored
...
08:15:28.179 ... Reconciling ConfigMap ... nonexistent-ca-certificate
08:15:28.179 ... Unable to get ConfigMap ... not found
08:15:28.179 ... Successfully reconciled ConfigMap ... action=ignored
```

## D) Envoy config changes from an intermediate state to TLS+SDS state

`run_56/cec_capture_89_20260308_081527.yaml` (`same-namespace`, generation 1) shows only route configuration entry and no backend clusters in that snapshot:

```yaml
metadata:
  generation: 1
  name: cilium-gateway-same-namespace
...
resources:
  - '@type': type.googleapis.com/envoy.config.route.v3.RouteConfiguration
    name: listener-insecure
```

`run_56/cec_capture_90_20260308_081529.yaml` (`same-namespace`, generation 4) shows both backend clusters with TLS transport sockets and SDS secret names:

```yaml
metadata:
  generation: 4
  name: cilium-gateway-same-namespace
...
- '@type': type.googleapis.com/envoy.config.cluster.v3.Cluster
  name: gateway-conformance-infra:backendtlspolicy-malformed-ca-certificate-ref-test:443
  transportSocket:
    typedConfig:
      commonTlsContext:
        combinedValidationContext:
          validationContextSdsSecretConfig:
            name: cilium-secrets/gateway-conformance-infra-cfgmap-malformed-ca-certificate
...
- '@type': type.googleapis.com/envoy.config.cluster.v3.Cluster
  name: gateway-conformance-infra:backendtlspolicy-nonexistent-ca-certificate-ref-test:443
  transportSocket:
    typedConfig:
      commonTlsContext:
        combinedValidationContext:
          validationContextSdsSecretConfig:
            name: cilium-secrets/gateway-conformance-infra-cfgmap-nonexistent-ca-certificate
```

## E) Request/response timeline from failing run

`run_56/run_56.log`:

```text
08:15:28.200  nonexistent subtest first request
08:15:28.203  HTTP/1.1 404 Not Found
08:15:29.209  HTTP/1.1 400 Bad Request
             "Client sent an HTTP request to an HTTPS server."
...
08:15:58.200  timeout while waiting after 30 attempts, 0/3 successes

08:15:58.207  malformed subtest first request
08:15:58.211  HTTP/1.1 400 Bad Request
08:15:59.216  HTTP/1.1 503 Service Unavailable
             "TLS error: Secret is not supplied by SDS"
```

`run_107/run_107.log` shows same shape:

```text
02:57:26.259  nonexistent gets 404 first
02:57:27.265  then 400
...
02:57:56.258  nonexistent times out after 30 attempts
02:57:57.281  malformed request passes (1.02s subtest)
```

## F) Envoy confirms 30s SDS timeout and post-timeout TLS failure

`run_56/cilium-envoy-jql56.log`:

```text
08:15:28.202 no route match for URL '/backendtlspolicy-nonexistent-ca-certificate-ref'
...
08:15:28.348 init manager Cluster ... nonexistent ... initializing shared target SdsApi cilium-secrets/...-cfgmap-nonexistent-ca-certificate
...
08:15:58.351 gRPC config: initial fetch timed out for ... tls.v3.Secret
08:15:58.351 shared target SdsApi ... malformed ... initialized
08:15:58.361 gRPC config: initial fetch timed out for ... tls.v3.Secret
08:15:58.361 shared target SdsApi ... nonexistent ... initialized
...
08:15:59.215 client disconnected, failure reason: TLS error: Secret is not supplied by SDS
08:15:59.215 upstream reset ... transport failure reason: TLS error: Secret is not supplied by SDS
```

`run_2/cilium-envoy-pp6v2.log` corroborates ~30s exactly:

```text
05:57:14.291 initializing shared target SdsApi ... malformed ...
05:57:44.291 initial fetch timed out for ... tls.v3.Secret
```

---

## Precise Root Cause

1. Cilium correctly marks both `BackendTLSPolicy` objects invalid (`Accepted=False`, `ResolvedRefs=False`).
2. In the same overall reconciliation window, Envoy data-plane config is still updated to use backend TLS origination with SDS CA secret references derived from policy refs.
3. `secretsync` intentionally does not materialize those secrets when policy is not accepted, so Envoy waits on SDS and eventually times out (~30s).
4. Before that timeout is reached, requests can hit transient/intermediate config states (`404` / `400`), and in captured failures the first subtest expires at 30s before Envoy emits consistent `5xx`.
5. The second subtest starts immediately after and catches post-timeout TLS failure (`503`), so it passes.

So the flake is not random protocol behavior; it is a deterministic race window created by control-plane ordering plus fixed test deadline.

---

## Why This Is Only ~3-5% (Rare)

The failure requires a narrow alignment:

- `nonexistent` subtest starts its 30s timer at `T_req0`.
- Envoy starts SDS wait at `T_sds_start` (after policy/config/xDS propagation).
- Envoy timeout-driven failure appears around `T_sds_start + 30s`.
- Flake occurs only when `T_sds_start + 30s > T_req0 + 30s` by enough margin that no `5xx` is observed before test timeout.

In failing captures this miss is small (hundreds of ms):

- `run_56`: nonexistent timeout at `08:15:58.200`, SDS timeout for nonexistent at `08:15:58.361` (~+161ms after deadline).
- `run_2`: nonexistent timeout at `05:57:43.977`, SDS timeout at `05:57:44.291` (~+314ms after deadline).

A small scheduling/propagation jitter decides pass vs fail; that naturally yields a low flake rate.

---

## Contributing Design Mismatch

There is a split-brain acceptance model:

- **Translation/ingestion path** uses referenced policy map to build TLS/SDS expectations.
- **Secret sync path** requires policy `Accepted=True` before publishing SDS secrets.

For invalid CA refs this creates "expect secret that will never arrive", and Envoy only resolves that after SDS initial-fetch timeout. This delayed resolution collides with conformance timing.

---

## Fix Directions

## 1) Primary fix (recommended)

Build and use an **effective policy map** for data-plane translation that includes only policies valid for the current Gateway (`Accepted=True` + refs resolved), not just conflict winners.

Expected outcome:

- Invalid policies do not produce backend TLS/SDS dependencies.
- No 30s SDS wait path for known-invalid refs.
- Behavior becomes deterministic and fast.

## 2) Deterministic invalid-policy response

When a route backend is targeted by a rejected `BackendTLSPolicy`, program an explicit local reply (`5xx`) until policy becomes valid. This directly matches conformance semantics and avoids transient `400/404`.

## 3) Reconcile/publish sequencing hardening

Avoid publishing intermediate xDS revisions for this route where policy state and backend/cluster state are inconsistent. Coalesce updates from policy/configmap/service watchers before pushing CEC generation.

## 4) Instrumentation improvements

Add explicit metrics/logs for:

- "policy invalid but TLS origination programmed"
- SDS secret expected-but-unsynced reason
- timestamps for policy-acceptance, CEC publish, SDS watch start, SDS timeout

This will make future flakes immediately explainable.

---

## Confidence and Gaps

Confidence is high on the timing-race RCA because it is supported by:

- policy status evidence,
- operator reconcile ordering evidence,
- CEC generation transitions,
- request/response traces,
- Envoy SDS initialization + timeout timestamps,
- repeated pattern across multiple failing runs.

Remaining uncertainty is only about exact micro-order between intermediate CEC revisions and request sampling at sub-second granularity; this does not change the core root cause or fix direction.

