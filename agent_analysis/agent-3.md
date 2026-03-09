# BackendTLSPolicy Invalid CA Ref Flake RCA

## Summary

This document is a standalone RCA for the flaky Gateway API conformance failure:

- Test: `TestConformance/BackendTLSPolicyInvalidCACertificateRef`
- Project: Cilium
- Observed failure: Envoy returns `400` or transiently `404` instead of the expected `500/502/503`
- Observed flake rate: roughly `3%`

The central finding is:

> Cilium correctly recognizes these `BackendTLSPolicy` objects as invalid in status, but still uses them when building the Envoy dataplane model. That allows a later reconcile to overwrite the correct `direct_response: 500` route with a broken routed backend that references CA material that will never be synced. The test fails only when the probe lands after that overwrite.

This is a control-plane race / consistency bug, not primarily a backend application bug.

## Test Scenario

The conformance test creates:

- an `HTTPRoute` with two paths
- a backend Service for each path
- a `BackendTLSPolicy` for each backend
- one policy references a non-existent CA `ConfigMap`
- one policy references a malformed `ConfigMap`

Expected behavior:

- requests to those backends should fail with a `5xx`

Observed failure behavior:

- requests receive `400`
- in at least one failing run, the first probe sees a transient `404`, then subsequent probes see `400`

## The Core Design Bug

The gateway reconciler builds `btlspMap` once from the raw `BackendTLSPolicy` list:

Source: `operator/pkg/gateway-api/gateway_reconcile.go`

```go
btlspList := &gatewayv1.BackendTLSPolicyList{}
if err := r.Client.List(ctx, btlspList); err != nil {
	return r.handleReconcileErrorWithStatus(ctx, err, original, gw)
}
btlspMap := helpers.BuildBackendTLSPolicyLookup(btlspList)
```

That map is then used in two places in the same reconcile:

1. `setBackendTLSPolicyStatuses(...)`
2. `ingestion.GatewayAPI(...)`

Source: `operator/pkg/gateway-api/gateway_reconcile.go`

```go
if err := r.setBackendTLSPolicyStatuses(scopedLog, ctx, httpRoutes, btlspMap, req.NamespacedName); err != nil {
	return controllerruntime.Fail(err)
}

httpListeners, tlsPassthroughListeners := ingestion.GatewayAPI(scopedLog, ingestion.Input{
	HTTPRoutes:          httpRoutes,
	TLSRoutes:           tlsRoutes,
	GRPCRoutes:          grpcRoutes,
	Services:            servicesList.Items,
	ServiceImports:      serviceImportsList.Items,
	ReferenceGrants:     grants.Items,
	BackendTLSPolicyMap: btlspMap,
})
```

The problem is that `BuildBackendTLSPolicyLookup(...)` only performs conflict resolution. It does **not** validate whether the policy is actually usable.

Source: `operator/pkg/gateway-api/helpers/backendtlspolicies.go`

```go
// BuildBackendTLSPolicyLookup builds a lookup map of BackendTLSPolicy by the NamespacedName of referenced
// backend Services. These are deduplicated using the Gateway API conflict resolution rules (oldest wins, then
// first lexicographically wins).
func BuildBackendTLSPolicyLookup(btlspList *gatewayv1.BackendTLSPolicyList) BackendTLSPolicyServiceMap {
	lookupMap := make(BackendTLSPolicyServiceMap)

	for _, currentBTLSP := range btlspList.Items {
		for _, targetRef := range currentBTLSP.Spec.TargetRefs {
			if !IsServiceTargetRef(targetRef) {
				continue
			}
            // ...
```

The `collection.Valid` bucket therefore means:

- "won targetRef conflict resolution"

It does **not** mean:

- "validated successfully"

That becomes fatal because model ingestion unconditionally consumes entries from `collection.Valid`.

Source: `operator/pkg/model/ingestion/gateway.go`

```go
for sectionName, btlsp := range collection.Valid {
	scopedLog.Debug("Checking valid BTLSP on port")

	if sectionName == "" {
		scopedLog.Debug("Got a match for valid BTLSP on all ports, adding")
		if be.TLS == nil {
			be.TLS = &model.BackendTLSOrigination{
				SNI: string(btlsp.Spec.Validation.Hostname),
			}
			if len(btlsp.Spec.Validation.CACertificateRefs) > 0 {
				be.TLS.CACertRef = &model.FullyQualifiedResource{
					Group:     "",
					Kind:      "ConfigMap",
					Version:   "v1",
					Name:      string(btlsp.Spec.Validation.CACertificateRefs[0].Name),
					Namespace: btlsp.GetNamespace(),
				}
			}
		}
	}
}
```

So even after validation marks the policy invalid, ingestion still attaches TLS origination details from that invalid policy to the backend.

## What Validation Actually Does

The validation path is correct. It rejects:

- missing CA `ConfigMap`
- malformed CA `ConfigMap` without `ca.crt`

Source: `operator/pkg/gateway-api/policychecks/backendtlspolicy.go`

```go
err := b.Client.Get(ctx, caCertRefKey, caCert)
if err != nil {
	if k8serrors.IsNotFound(err) {
		b.setRejectedConditions(ancestorRef, fmt.Sprintf("CA Certificate does not exist: %s", caCertRefKey),
			string(gatewayv1.BackendTLSPolicyReasonNoValidCACertificate), string(gatewayv1.BackendTLSPolicyReasonInvalidCACertificateRef))
		return false, nil
	}
	return false, err
}

if _, ok := caCert.Data["ca.crt"]; !ok {
	b.setRejectedConditions(ancestorRef, "CA Certificate ConfigMap does not contain a `ca.crt` key",
		string(gatewayv1.BackendTLSPolicyReasonNoValidCACertificate), string(gatewayv1.BackendTLSPolicyReasonInvalidCACertificateRef))
	return false, nil
}
```

The failing captures confirm these invalid conditions were actually written.

### Status evidence from `run_2`

Source: `example_failure_data/run_2/gwapi_capture_100_20260308_055727.yaml`

```yaml
- apiVersion: gateway.networking.k8s.io/v1
  kind: BackendTLSPolicy
  metadata:
    name: malformed-ca-certificate-ref
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
```

```yaml
- apiVersion: gateway.networking.k8s.io/v1
  kind: BackendTLSPolicy
  metadata:
    name: nonexistent-ca-certificate-ref
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

`run_56` shows the same invalid statuses.

## Why Secret Sync Does Not Save This

Secret sync is gated by policy acceptance. It only considers a CA `ConfigMap` relevant if a referencing `BackendTLSPolicy` is `Accepted=True` for the Cilium gateway controller.

Source: `operator/pkg/gateway-api/secretsync.go`

```go
for _, btlsp := range btlspList.Items {
	for _, ancestorStatus := range btlsp.Status.Ancestors {
		if ancestorStatus.ControllerName == controllerName && helpers.IsAccepted(ancestorStatus.Conditions) {
			return true
		}
	}
}
return false
```

That means:

- invalid `BackendTLSPolicy` status blocks CA secret sync
- but ingestion still references the CA anyway

This is the inconsistency at the heart of the flake.

## Reconstructed Failure Sequence

The same broad sequence appears in both `run_2` and `run_56`.

### Step 1: Cilium briefly programs the correct failure mode

The correct behavior is a local `direct_response: 500` for both paths when no valid backend remains.

Agent evidence from `run_2`:

Source: `example_failure_data/run_2/cilium-hln54.log`

```text
time=2026-03-08T05:57:13.835101812Z ... msg="ParseResources: Parsed route" ...
route="name:\"gateway-conformance-infra/cilium-gateway-same-namespace/listener-insecure\"
  virtual_hosts:{
    ...
    routes:{match:{path:\"/backendtlspolicy-nonexistent-ca-certificate-ref\"}  direct_response:{status:500  body:{inline_string:\"\"}}}
    routes:{match:{path:\"/backendtlspolicy-malformed-ca-certificate-ref\"}  direct_response:{status:500  body:{inline_string:\"\"}}}
  }"
```

Agent evidence from `run_56`:

Source: `example_failure_data/run_56/cilium-fln42.log`

```text
time=2026-03-08T08:15:28.142785519Z ... msg="ParseResources: Parsed route" ...
route="name:\"gateway-conformance-infra/cilium-gateway-same-namespace/listener-insecure\"
  virtual_hosts:{
    ...
    routes:{match:{path:\"/backendtlspolicy-nonexistent-ca-certificate-ref\"}  direct_response:{status:500  body:{inline_string:\"\"}}}
    routes:{match:{path:\"/backendtlspolicy-malformed-ca-certificate-ref\"}  direct_response:{status:500  body:{inline_string:\"\"}}}
  }"
```

This proves that the system can reach the correct intended state.

### Step 2: Secret sync refuses to create CA material

Because the policies are invalid, secret sync does not create the corresponding CA secrets.

Operator evidence from `run_2`:

Source: `example_failure_data/run_2/cilium-operator-85cfd5c96b-mtdch.log`

```text
time=2026-03-08T05:57:13.846724992Z ... msg="Unable to get ConfigMap - either deleted or not yet available"
resource=gateway-conformance-infra/nonexistent-ca-certificate
error="ConfigMap \"nonexistent-ca-certificate\" not found"

time=2026-03-08T05:57:13.846798322Z ... msg="Successfully reconciled ConfigMap"
resource=gateway-conformance-infra/nonexistent-ca-certificate action=ignored

time=2026-03-08T05:57:13.856056471Z ... msg="Unable to get ConfigMap - either deleted or not yet available"
resource=gateway-conformance-infra/malformed-ca-certificate
error="ConfigMap \"malformed-ca-certificate\" not found"

time=2026-03-08T05:57:13.856079751Z ... msg="Successfully reconciled ConfigMap"
resource=gateway-conformance-infra/malformed-ca-certificate action=ignored
```

Operator evidence from `run_56`:

Source: `example_failure_data/run_56/cilium-operator-85cfd5c96b-d6kcf.log`

```text
time=2026-03-08T08:15:28.14429332Z ... msg="Unable to get ConfigMap - either deleted or not yet available"
resource=gateway-conformance-infra/nonexistent-ca-certificate
error="ConfigMap \"nonexistent-ca-certificate\" not found"

time=2026-03-08T08:15:28.1443281Z ... msg="Successfully reconciled ConfigMap"
resource=gateway-conformance-infra/nonexistent-ca-certificate action=ignored

time=2026-03-08T08:15:28.153202312Z ... msg="Unable to get ConfigMap - either deleted or not yet available"
resource=gateway-conformance-infra/malformed-ca-certificate
error="ConfigMap \"malformed-ca-certificate\" not found"

time=2026-03-08T08:15:28.153236972Z ... msg="Successfully reconciled ConfigMap"
resource=gateway-conformance-infra/malformed-ca-certificate action=ignored
```

This matters because the later routed cluster will reference SDS secrets that never become available.

### Step 3: The same invalid policies are still consumed during model ingestion

This is the key evidence that the controller is using policies that were just rejected.

Operator evidence from `run_2`:

Source: `example_failure_data/run_2/cilium-operator-85cfd5c96b-mtdch.log`

```text
time=2026-03-08T05:57:13.89816777Z ... msg="Validating BackendTLSPolicy spec"
backendTLSPolicyName=gateway-conformance-infra/nonexistent-ca-certificate-ref

time=2026-03-08T05:57:13.898257281Z ... msg="Validating BackendTLSPolicy spec"
backendTLSPolicyName=gateway-conformance-infra/malformed-ca-certificate-ref

time=2026-03-08T05:57:13.898391321Z ... msg="Checking valid BTLSP on port"
service=gateway-conformance-infra/backendtlspolicy-nonexistent-ca-certificate-ref-test
backendTLSPolicyName=nonexistent-ca-certificate-ref

time=2026-03-08T05:57:13.898400021Z ... msg="Got a match for valid BTLSP on all ports, adding"
service=gateway-conformance-infra/backendtlspolicy-nonexistent-ca-certificate-ref-test
backendTLSPolicyName=nonexistent-ca-certificate-ref

time=2026-03-08T05:57:13.898435401Z ... msg="Checking valid BTLSP on port"
service=gateway-conformance-infra/backendtlspolicy-malformed-ca-certificate-ref-test
backendTLSPolicyName=malformed-ca-certificate-ref

time=2026-03-08T05:57:13.89844253Z ... msg="Got a match for valid BTLSP on all ports, adding"
service=gateway-conformance-infra/backendtlspolicy-malformed-ca-certificate-ref-test
backendTLSPolicyName=malformed-ca-certificate-ref
```

Operator evidence from `run_56`:

Source: `example_failure_data/run_56/cilium-operator-85cfd5c96b-d6kcf.log`

```text
time=2026-03-08T08:15:28.202259279Z ... msg="Validating BackendTLSPolicy spec"
backendTLSPolicyName=gateway-conformance-infra/nonexistent-ca-certificate-ref

time=2026-03-08T08:15:28.202337159Z ... msg="Validating BackendTLSPolicy spec"
backendTLSPolicyName=gateway-conformance-infra/malformed-ca-certificate-ref

time=2026-03-08T08:15:28.202429499Z ... msg="Checking valid BTLSP on port"
service=gateway-conformance-infra/backendtlspolicy-nonexistent-ca-certificate-ref-test
backendTLSPolicyName=nonexistent-ca-certificate-ref

time=2026-03-08T08:15:28.202437559Z ... msg="Got a match for valid BTLSP on all ports, adding"
service=gateway-conformance-infra/backendtlspolicy-nonexistent-ca-certificate-ref-test
backendTLSPolicyName=nonexistent-ca-certificate-ref
```

This is the strongest direct proof of the bug:

- the controller validated the policy as invalid
- the controller then treated the same policy as a valid backend TLS policy during ingestion

### Step 4: Cilium overwrites the correct `500` route with routed clusters using broken TLS origination

Operator evidence from `run_2`:

Source: `example_failure_data/run_2/cilium-operator-85cfd5c96b-mtdch.log`

```text
time=2026-03-08T05:57:13.89734275Z ... msg="CEC unmarshaled XDS Resource"
resource="[type.googleapis.com/envoy.config.route.v3.RouteConfiguration]:  {
  name:  \"listener-insecure\"
  virtual_hosts:  {
    ...
    routes:  {
      match:  { path:  \"/backendtlspolicy-nonexistent-ca-certificate-ref\" }
      route:  { cluster:  \"gateway-conformance-infra:backendtlspolicy-nonexistent-ca-certificate-ref-test:443\" }
    }
    routes:  {
      match:  { path:  \"/backendtlspolicy-malformed-ca-certificate-ref\" }
      route:  { cluster:  \"gateway-conformance-infra:backendtlspolicy-malformed-ca-certificate-ref-test:443\" }
    }
  }
}"
```

```text
time=2026-03-08T05:57:13.89791909Z ... msg="CEC unmarshaled XDS Resource"
resource="[type.googleapis.com/envoy.config.cluster.v3.Cluster]:  {
  name:  \"gateway-conformance-infra:backendtlspolicy-nonexistent-ca-certificate-ref-test:443\"
  ...
  transport_socket:  {
    name:  \"envoy.transport_sockets.tls\"
    typed_config:  {
      [type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext]:  {
        common_tls_context:  {
          combined_validation_context:  {
            default_validation_context:  {}
            validation_context_sds_secret_config:  {
              name:  \"cilium-secrets/gateway-conformance-infra-cfgmap-nonexistent-ca-certificate\"
            }
          }
        }
        sni:  \"abc.example.com\"
      }
    }
  }
}"
```

Operator evidence from `run_56`:

Source: `example_failure_data/run_56/cilium-operator-85cfd5c96b-d6kcf.log`

```text
time=2026-03-08T08:15:28.201093828Z ... msg="CEC unmarshaled XDS Resource"
resource="[type.googleapis.com/envoy.config.route.v3.RouteConfiguration]:  {
  name:  \"listener-insecure\"
  virtual_hosts:  {
    ...
    routes:  {
      match:  { path:  \"/backendtlspolicy-nonexistent-ca-certificate-ref\" }
      route:  { cluster:  \"gateway-conformance-infra:backendtlspolicy-nonexistent-ca-certificate-ref-test:443\" }
    }
  }
}"
```

```text
time=2026-03-08T08:15:28.201447888Z ... msg="CEC unmarshaled XDS Resource"
resource="[type.googleapis.com/envoy.config.cluster.v3.Cluster]:  {
  name:  \"gateway-conformance-infra:backendtlspolicy-nonexistent-ca-certificate-ref-test:443\"
  ...
  transport_socket:  {
    name:  \"envoy.transport_sockets.tls\"
    typed_config:  {
      [type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext]:  {
        common_tls_context:  {
          combined_validation_context:  {
            default_validation_context:  {}
            validation_context_sds_secret_config:  {
              name:  \"cilium-secrets/gateway-conformance-infra-cfgmap-nonexistent-ca-certificate\"
            }
          }
        }
        sni:  \"abc.example.com\"
      }
    }
  }
}"
```

So the correct `500` behavior is being replaced with an attempt to route upstream using:

- TLS origination
- SNI `abc.example.com`
- CA SDS secret `cilium-secrets/gateway-conformance-infra-cfgmap-<name>`

But those CA secrets are never synced.

### Step 5: The probe lands after the bad overwrite and sees `400`

Conformance log from `run_2`:

Source: `example_failure_data/run_2/run_2.log`

```text
2026-03-08T05:57:13.977004909Z: Making GET request to host abc.example.com via http://192.168.8.240/backendtlspolicy-nonexistent-ca-certificate-ref

2026-03-08T05:57:13.982042348Z: ... expected status code to be one of [500 502 503], got 400.
CRes: &{400 -1 HTTP/1.1 map[Date:[Sun, 08 Mar 2026 05:57:13 GMT] Server:[envoy] X-Envoy-Upstream-Service-Time:[0]] <nil> []}
```

Conformance log from `run_56`:

Source: `example_failure_data/run_56/run_56.log`

```text
2026-03-08T08:15:28.200566978Z: Making GET request to host abc.example.com via http://192.168.8.240/backendtlspolicy-nonexistent-ca-certificate-ref

2026-03-08T08:15:28.203675889Z: ... expected status code to be one of [500 502 503], got 404.
CRes: &{404 0 HTTP/1.1 map[Content-Length:[0] Date:[Sun, 08 Mar 2026 08:15:27 GMT] Server:[envoy]] <nil> []}

2026-03-08T08:15:29.2096879Z: ... expected status code to be one of [500 502 503], got 400.
CRes: &{400 -1 HTTP/1.1 map[Date:[Sun, 08 Mar 2026 08:15:28 GMT] Server:[envoy] X-Envoy-Upstream-Service-Time:[0]] <nil> []}
```

The important part is not the exact internal Envoy code path for `400`; it is that the intended local `500` route is gone by the time the probe evaluates readiness.

## Why This Only Fails Around 3%

This is best explained as a narrow race window between:

1. the initial reconcile that produces the correct `direct_response: 500`
2. fast follow-up reconciles that overwrite the route with the broken routed cluster
3. the conformance client beginning its probe loop

The captured timings are tight:

- `run_56`
  - correct `500` route parsed at `08:15:28.142785519`
  - bad routed config emitted at `08:15:28.201093828`
  - first probe at `08:15:28.200566978`
  - first observed result `404`, then steady `400`

- `run_2`
  - correct `500` route parsed at `05:57:13.835101812`
  - bad routed config parsed by agent at `05:57:13.884739811`
  - bad routed cluster emitted by operator at `05:57:13.89791909`
  - first probe at `05:57:13.977004909`
  - first observed result already `400`

So the system is churning between states within roughly tens of milliseconds.

That explains the low failure rate:

- if the test probes while the correct `500` direct response is active, the run passes
- if the test probes after the later broken routed config takes over, the run fails
- because that transition window is short, only a minority of runs hit it

`run_2` also contains an additional reconcile conflict:

Source: `example_failure_data/run_2/cilium-operator-85cfd5c96b-mtdch.log`

```text
time=2026-03-08T05:57:13.868862971Z ... msg="Reconciler error" ...
error="failed to update Gateway status: Operation cannot be fulfilled on gateways.gateway.networking.k8s.io \"same-namespace\": the object has been modified; please apply your changes to the latest version and try again"
```

That failure would trigger another immediate reconcile and likely increases the chance of the bad overwrite racing with the test probe.

I would treat that as an amplifier, not the root cause.

## Why the Response Is `400` Instead of `500`

What is fully proven:

- Envoy is no longer serving the intended local `direct_response: 500`
- Envoy is instead attempting to use a routed cluster with TLS origination
- that cluster references SDS CA material that was never created
- the observed responses are local `400`s with `X-Envoy-Upstream-Service-Time:[0]`

What is not fully proven from the current captures:

- the exact Envoy-internal reason this broken routed state manifests as `400` rather than a different local failure code

The control-plane RCA does not depend on answering that final internal Envoy detail. The test fails because Cilium replaces the correct `500` route with an invalid routed configuration.

## Bottom-Line Root Cause

The root cause is an inconsistency between validation/status logic and dataplane generation:

- `BackendTLSPolicy` validation correctly rejects invalid CA references
- secret sync correctly refuses to sync CA material for rejected policies
- but the gateway model builder still consumes those same rejected policies because `btlspMap` is derived before validation and its `Valid` set only reflects conflict resolution, not semantic validity

This causes the controller to oscillate between:

- correct state: route returns `direct_response: 500`
- incorrect state: route forwards to a backend cluster with TLS origination that depends on CA secrets that will never exist

The flake exists because the test only fails when the readiness probe lands after the incorrect state has replaced the correct one.

## Most Likely Fix Direction

The most likely fix is to stop ingestion from using invalid `BackendTLSPolicy` objects.

Possible ways to do that:

1. rebuild or filter `btlspMap` after validation so only semantically valid policies are passed into `ingestion.GatewayAPI(...)`
2. change `BuildBackendTLSPolicyLookup(...)` / downstream data structures so conflict resolution and semantic validity are represented separately
3. teach `addBackendTLSDetails(...)` to ignore policies whose validation/status for the current gateway is not accepted

The key requirement is:

> once a `BackendTLSPolicy` is known to be invalid, it must not participate in backend TLS origination for Envoy config generation

## Confidence / Gaps

High confidence:

- on the control-plane race / stale-map explanation
- on the event ordering described above
- on the explanation for the low flake rate

Medium confidence:

- on the exact mechanism that produces the final `400` inside Envoy

Further evidence that would be useful, but is not required for the RCA:

- an Envoy admin dump of active route / cluster / secret state at the exact first failing probe
- more explicit Envoy logs around the local reply path that generated the `400`

## Practical Conclusion

This flake is caused by Cilium briefly doing the right thing, then overwriting that good state with a broken routed state derived from already-invalid `BackendTLSPolicy` objects. The test only fails when the probe lands after that overwrite, which explains the low but persistent flake rate.
