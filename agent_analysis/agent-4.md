# Root Cause Analysis: BackendTLSPolicyInvalidCACertificateRef Flaky Test Failure

**Test**: `TestConformance/BackendTLSPolicyInvalidCACertificateRef`
**Project**: Cilium (Gateway API conformance tests)
**Failure Rate**: ~5% in GitHub Actions CI/CD
**Symptom**: Test expects HTTP 5xx but receives HTTP 400

---

## 1. Executive Summary

The test fails because of a **race condition in the Cilium operator's gateway reconciler**. When Gateway API resources (HTTPRoute, Services, BackendTLSPolicies) are created in rapid succession, the operator can reconcile the gateway **before** BackendTLSPolicies exist. This produces an intermediate `CiliumEnvoyConfig` (CEC) where backend clusters are configured **without TLS transport sockets**. Envoy then forwards plaintext HTTP to a TLS backend on port 8443, which responds with HTTP 400 ("Client sent an HTTP request to an HTTPS server") instead of the expected 5xx.

The ~5% failure rate corresponds to how often the operator's reconciliation loop "wins the race" against resource creation -- completing a non-TLS CEC update within the ~61ms window between HTTPRoute and BackendTLSPolicy creation.

---

## 2. Test Design

### 2.1 What the Test Creates

The test applies a single YAML manifest that defines these resources (in order within the file):

1. **HTTPRoute** `backendtlspolicy-invalid-ca-certificate-ref` -- routes two paths to two backend services
2. **Service** `backendtlspolicy-nonexistent-ca-certificate-ref-test` -- selects `app: tls-backend`, port 443 (targetPort 8443, appProtocol HTTPS)
3. **Service** `backendtlspolicy-malformed-ca-certificate-ref-test` -- same configuration
4. **BackendTLSPolicy** `nonexistent-ca-certificate-ref` -- references a ConfigMap `nonexistent-ca-certificate` that does **not exist**
5. **BackendTLSPolicy** `malformed-ca-certificate-ref` -- references a ConfigMap `malformed-ca-certificate` that exists but has **empty data**
6. **ConfigMap** `malformed-ca-certificate` -- `data: {}` (no CA cert content)

The key test YAML:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backendtlspolicy-invalid-ca-certificate-ref
  namespace: gateway-conformance-infra
spec:
  parentRefs:
    - name: same-namespace
      namespace: gateway-conformance-infra
  hostnames:
    - abc.example.com
  rules:
    - backendRefs:
        - name: backendtlspolicy-nonexistent-ca-certificate-ref-test
          port: 443
      matches:
        - path:
            type: Exact
            value: /backendtlspolicy-nonexistent-ca-certificate-ref
    - backendRefs:
        - name: backendtlspolicy-malformed-ca-certificate-ref-test
          port: 443
      matches:
        - path:
            type: Exact
            value: /backendtlspolicy-malformed-ca-certificate-ref
---
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
apiVersion: v1
kind: ConfigMap
metadata:
  name: malformed-ca-certificate
  namespace: gateway-conformance-infra
data: {}
```

### 2.2 What the Test Asserts

The Go test definition iterates over both BackendTLSPolicies and for each:
1. Checks that `Accepted` condition is `False` with reason `NoValidCACertificate` (this always passes)
2. Checks that `ResolvedRefs` condition is `False` with reason `InvalidCACertificateRef` (this always passes)
3. Makes HTTP requests expecting **status codes 500, 502, or 503** (this is where the flake occurs)

The critical assertion code:

```go
h.MakeRequestAndExpectEventuallyConsistentResponse(t, suite.RoundTripper, suite.TimeoutConfig, gwAddr,
    h.ExpectedResponse{
        Namespace: ns,
        Request: h.Request{
            Host: serverStr,
            Path: "/backendtlspolicy-" + policyNN.Name,
        },
        Response: h.Response{
            StatusCodes: []int{500, 502, 503},
        },
    })
```

The test iterates over the policies in this order: `nonexistent-ca-certificate-ref` first, then `malformed-ca-certificate-ref`. Each subtest has a 30-second timeout for the HTTP assertion. The `nonexistent` subtest must complete (pass or fail) before the `malformed` subtest starts.

### 2.3 Expected Behavior

When a BackendTLSPolicy references an invalid CA certificate, the gateway should:
- Mark the policy as not accepted
- Either refuse to route to the backend, or attempt TLS with the invalid cert and fail

In both cases, the HTTP response should be a **5xx error**. A 400 error is incorrect because it means Envoy forwarded plaintext HTTP to a TLS-only backend.

---

## 3. Architecture: How Cilium Implements BackendTLSPolicy

Understanding the architecture is essential to understanding the race condition.

### 3.1 Controller Watches

The gateway controller (`operator/pkg/gateway-api/gateway.go`) watches multiple resource types that trigger gateway reconciliation:

```go
gatewayBuilder := ctrl.NewControllerManagedBy(mgr).
    For(&gatewayv1.Gateway{}, ...).
    Watches(&corev1.Service{}, r.enqueueRequestForBackendService()).
    Watches(&gatewayv1.HTTPRoute{}, r.enqueueRequestForOwningHTTPRoute(r.logger)).
    Watches(&gatewayv1.BackendTLSPolicy{}, r.enqueueRequestForBackendTLSPolicy()).
    Watches(&corev1.ConfigMap{}, r.enqueueRequestForBackendTLSPolicyConfigMap()).
    Owns(&ciliumv2.CiliumEnvoyConfig{}).
    // ...
```

Each resource creation (HTTPRoute, Service, BackendTLSPolicy, ConfigMap) enqueues the parent Gateway for reconciliation. This means a single test manifest creates **multiple reconciliation events** in rapid succession.

### 3.2 Reconciliation Logic

The reconciliation function (`operator/pkg/gateway-api/gateway_reconcile.go`) performs a point-in-time snapshot of all relevant resources:

```go
// Line 124-129: List all BackendTLSPolicies AT THIS INSTANT
btlspList := &gatewayv1.BackendTLSPolicyList{}
if err := r.Client.List(ctx, btlspList); err != nil {
    scopedLog.ErrorContext(ctx, "Unable to list BackendTLSPolicies", logfields.Error, err)
    return r.handleReconcileErrorWithStatus(ctx, err, original, gw)
}
btlspMap := helpers.BuildBackendTLSPolicyLookup(btlspList)
```

This `btlspMap` is then used for both:
1. **Status updates** (line 181): setting `Accepted`/`ResolvedRefs` conditions on BackendTLSPolicies
2. **CEC ingestion** (line 196): translating the gateway configuration into a CiliumEnvoyConfig

```go
// Line 186-197: btlspMap is passed to the ingestion layer
httpListeners, tlsPassthroughListeners := ingestion.GatewayAPI(scopedLog, ingestion.Input{
    GatewayClass:        *gwc,
    Gateway:             *gw,
    HTTPRoutes:          httpRoutes,
    Services:            servicesList.Items,
    BackendTLSPolicyMap: btlspMap,  // <-- point-in-time snapshot
})
```

**The critical insight**: If `btlspMap` is empty (because BackendTLSPolicies haven't been created yet), the ingestion layer produces a CEC with clusters that have **no TLS configuration**.

### 3.3 Ingestion: addBackendTLSDetails

The function `addBackendTLSDetails` in `operator/pkg/model/ingestion/gateway.go` decides whether to add TLS origination to a backend:

```go
func addBackendTLSDetails(log *slog.Logger, be model.Backend, svc *corev1.Service,
    btlspMap helpers.BackendTLSPolicyServiceMap) model.Backend {

    svcFullName := types.NamespacedName{Name: svc.GetName(), Namespace: svc.GetNamespace()}

    // Check for relevant BackendTLSPolicies
    if collection, ok := btlspMap[svcFullName]; ok {
        // A BackendTLSPolicy exists for this service
        for _, port := range svc.Spec.Ports {
            if port.Port != int32(be.Port.Port) {
                continue
            }
            for sectionName, btlsp := range collection.Valid {
                if sectionName == "" {
                    // Match on all ports
                    be.TLS = &model.BackendTLSOrigination{
                        SNI: string(btlsp.Spec.Validation.Hostname),
                    }
                    if len(btlsp.Spec.Validation.CACertificateRefs) > 0 {
                        be.TLS.CACertRef = &model.FullyQualifiedResource{
                            Name:      string(btlsp.Spec.Validation.CACertificateRefs[0].Name),
                            Namespace: btlsp.GetNamespace(),
                            // ...
                        }
                    }
                }
            }
        }
    }
    // If btlspMap has no entry for this service: TLS remains nil
    return be
}
```

When `btlspMap` is empty, the function returns the backend unchanged with `TLS: <nil>`. No TLS origination is configured.

### 3.4 Translation: withTLSOrigination

The cluster mutator `withTLSOrigination` in `operator/pkg/model/translation/envoy_cluster_mutator.go` adds an Envoy transport socket only when TLS config exists:

```go
func withTLSOrigination(tls *model.BackendTLSOrigination) ClusterMutator {
    return func(cluster *envoy_config_cluster_v3.Cluster) *envoy_config_cluster_v3.Cluster {
        if tls == nil {
            return cluster  // No transport_socket added!
        }
        if tls.SNI == "" {
            return cluster
        }
        if tls.CACertRef == nil || tls.CACertRef.Name == "" || tls.CACertRef.Namespace == "" {
            return cluster
        }

        tlsContext := &envoy_config_tls.UpstreamTlsContext{
            Sni: tls.SNI,
            CommonTlsContext: &envoy_config_tls.CommonTlsContext{
                ValidationContextType: &envoy_config_tls.CommonTlsContext_CombinedValidationContext{
                    CombinedValidationContext: &envoy_config_tls.CommonTlsContext_CombinedCertificateValidationContext{
                        ValidationContextSdsSecretConfig: &envoy_config_tls.SdsSecretConfig{
                            Name: "cilium-secrets/" + tls.CACertRef.Namespace +
                                  "-cfgmap-" + tls.CACertRef.Name,
                        },
                    },
                },
            },
        }
        cluster.TransportSocket = &envoy_config_core_v3.TransportSocket{
            Name: "envoy.transport_sockets.tls",
            ConfigType: &envoy_config_core.TransportSocket_TypedConfig{
                TypedConfig: toAny(tlsContext),
            },
        }
        return cluster
    }
}
```

When `tls == nil` (as happens when no BackendTLSPolicy is found), the cluster gets **no transport socket**. Envoy will send plaintext to the backend.

### 3.5 SDS Secret Sync

The secret sync mechanism (`operator/pkg/gateway-api/secretsync.go`) determines whether a ConfigMap should be synced to Cilium's secret namespace for SDS:

```go
func ConfigMapIsReferencedInCiliumGateway(ctx context.Context, c client.Client,
    logger *slog.Logger, cfgMap *corev1.ConfigMap) bool {

    btlspList := &gatewayv1.BackendTLSPolicyList{}
    if err := c.List(ctx, btlspList, &client.ListOptions{
        FieldSelector: fields.OneTermEqualSelector(
            indexers.BackendTLSPolicyConfigMapIndex, cfgMapName.String()),
    }); err != nil {
        return false
    }
    if len(btlspList.Items) == 0 {
        return false
    }

    for _, btlsp := range btlspList.Items {
        for _, ancestorStatus := range btlsp.Status.Ancestors {
            if ancestorStatus.ControllerName == controllerName &&
               helpers.IsAccepted(ancestorStatus.Conditions) {
                return true
            }
        }
    }
    return false  // Not synced if policy is not Accepted
}
```

For this test, the BackendTLSPolicies are marked `Accepted: False` (invalid CA certs). Therefore, the ConfigMaps are **never synced** to `cilium-secrets`, and the SDS secrets referenced in the Envoy cluster config never exist.

---

## 4. The Race Condition (Proven from Failure Data)

### 4.1 Resource Creation Timeline

From the test log (`run_2/run_2.log`) and operator log (`run_2/cilium-operator-85cfd5c96b-mtdch.log`), the resources are created in this order:

| Timestamp | Delta | Event |
|-----------|-------|-------|
| `05:57:13.777` | T+0ms | HTTPRoute created |
| `05:57:13.787` | T+10ms | Service `nonexistent...test` created |
| `05:57:13.801` | T+24ms | Service `malformed...test` created |
| `05:57:13.838` | T+61ms | BackendTLSPolicy `nonexistent-ca-certificate-ref` created |
| `05:57:13.851` | T+74ms | BackendTLSPolicy `malformed-ca-certificate-ref` created |
| `05:57:13.859` | T+82ms | ConfigMap `malformed-ca-certificate` created |

The HTTPRoute is created **61ms before** the first BackendTLSPolicy. This window is where the race occurs.

### 4.2 Three Reconciliations in ~100ms

The operator log shows three consecutive reconciliations of the `same-namespace` gateway:

#### Reconciliation 1 (T+8ms): HTTPRoute triggers, policies=0

```
time=05:57:13.784  msg="Reconciling Gateway" resource=same-namespace
time=05:57:13.792  msg="Updating BackendTLSPolicy statuses" policies=0
```

The `List BackendTLSPolicies` at `05:57:13.792` finds **0 policies** because they haven't been created yet (created at `05:57:13.838`). The resulting CEC has `direct_response: 500` routes (safe -- no clusters created):

```
# CEC RouteConfiguration at 05:57:13.808 (from agent log line 6405):
routes {
  match { path: "/backendtlspolicy-nonexistent-ca-certificate-ref" }
  direct_response { status: 500 }
}
routes {
  match { path: "/backendtlspolicy-malformed-ca-certificate-ref" }
  direct_response { status: 500 }
}
```

#### Reconciliation 2 (T+48ms): Services trigger, still policies=0

```
time=05:57:13.825  msg="Reconciling Gateway" resource=same-namespace
time=05:57:13.846  msg="Updating BackendTLSPolicy statuses" policies=0
time=05:57:13.846  msg="Checking Backend TLS Details" service=...nonexistent... TLS:<nil>
time=05:57:13.846  msg="Checking Backend TLS Details" service=...malformed... TLS:<nil>
```

Now the Services exist, so backends can be resolved. But `policies=0` -- still no BackendTLSPolicies. The ingestion layer sets `TLS: <nil>` for both backends. The CEC now has routes pointing to clusters, **WITHOUT transport sockets**:

```
# CEC Cluster at 05:57:13.862 (from agent log line 6414):
# NOTE: NO transport_socket field!
name: "gateway-conformance-infra:backendtlspolicy-malformed-ca-certificate-ref-test:443"
type: EDS
eds_cluster_config {
  service_name: "gateway-conformance-infra/backendtlspolicy-malformed...test:443"
}
typed_extension_protocol_options { ... HttpProtocolOptions ... }
outlier_detection { split_external_local_origin_errors: true }
# ^^^ No transport_socket means Envoy sends PLAINTEXT to this backend
```

This reconciliation then **fails on Gateway status update** (conflict error), but the **CEC update succeeded**:

```
time=05:57:13.868  msg="Reconciler error"
    error="failed to update Gateway status: ...the object has been modified;
           please apply your changes to the latest version and try again"
```

#### Reconciliation 3 (T+92ms): Retry, policies=2

```
time=05:57:13.868  msg="Reconciling Gateway" resource=same-namespace
time=05:57:13.869  msg="Updating BackendTLSPolicy statuses" policies=2
time=05:57:13.881  msg="Got a match for valid BTLSP on all ports, adding"
                   service=...nonexistent...
time=05:57:13.881  msg="Got a match for valid BTLSP on all ports, adding"
                   service=...malformed...
```

Now the BackendTLSPolicies are visible. The CEC has clusters **WITH transport sockets and SDS secret references**:

```
# CEC Cluster at 05:57:13.897 (from agent log line 6438):
name: "gateway-conformance-infra:backendtlspolicy-malformed-ca-certificate-ref-test:443"
type: EDS
eds_cluster_config { ... }
outlier_detection { ... }
transport_socket {
  name: "envoy.transport_sockets.tls"
  typed_config {
    [UpstreamTlsContext] {
      common_tls_context {
        combined_validation_context {
          validation_context_sds_secret_config {
            name: "cilium-secrets/gateway-conformance-infra-cfgmap-malformed-ca-certificate"
            sds_config {
              initial_fetch_timeout { seconds: 30 }  # <-- Critical: 30s timeout
            }
          }
        }
      }
      sni: "abc.example.com"
    }
  }
}
```

### 4.3 CEC State Progression Summary

The CEC `cilium-gateway-same-namespace` went through three states within ~100ms:

| CEC Gen | Timestamp | Route Target | Cluster Transport Socket |
|---------|-----------|-------------|------------------------|
| Gen 2 | `05:57:13.808` | `direct_response: 500` | N/A (no clusters) |
| Gen 3 | `05:57:13.861` | Cluster routing | **NO** TLS transport socket |
| Gen 4 | `05:57:13.897` | Cluster routing | **YES** TLS + SDS references |

---

## 5. What the Cilium Agent Pushed to Envoy (Proven)

The Cilium agent log (`run_2/cilium-hln54.log`) confirms it received all three CEC versions and processed them.

### 5.1 Agent Receives Gen 2 (direct_response:500)

```
# Agent log line 6405, at 05:57:13.812:
CEC unmarshaled XDS Resource: RouteConfiguration
  routes { match { path: "/backendtlspolicy-nonexistent..." }
           direct_response { status: 500 } }
```

### 5.2 Agent Receives Gen 3 (clusters WITHOUT TLS)

```
# Agent log line 6414-6415, at 05:57:13.863:
CEC unmarshaled XDS Resource: Cluster
  name: "...backendtlspolicy-malformed-ca-certificate-ref-test:443"
  type: EDS
  outlier_detection { ... }
  # NO transport_socket field
```

### 5.3 Agent Receives Gen 4 (clusters WITH TLS)

```
# Agent log line 6438, at 05:57:13.897:
CEC unmarshaled XDS Resource: Cluster
  name: "...backendtlspolicy-malformed-ca-certificate-ref-test:443"
  type: EDS
  transport_socket {
    name: "envoy.transport_sockets.tls"
    typed_config { UpstreamTlsContext with SDS config }
  }
```

### 5.4 Agent Pushes to Envoy's xDS Cache

At `05:57:13.936`, the agent executes `UpdateEnvoyResources`:

```
# Agent log line 6446-6450:
UpdateEnvoyResources: listeners  deleted=0 upserted=1
UpdateEnvoyResources: routes     deleted=0 upserted=1
UpdateEnvoyResources: clusters   deleted=0 upserted=2
UpdateEnvoyResources: endpoints  deleted=0 upserted=0
UpdateEnvoyResources: secrets    deleted=0 upserted=0
```

The agent pushed 2 clusters. Looking at the cache operations, the clusters inserted include TLS transport sockets (Gen 4). No secrets were upserted (`secrets upserted=0`).

### 5.5 SDS Secret Resolution Fails

At `05:57:14.043`, Envoy initiates SDS streams for both secrets. The agent's SDS server responds with "resource not found":

```
# Agent log line 6615:
resource not found  xdsTypeURL=...Secret
  xdsResourceName=cilium-secrets/gateway-conformance-infra-cfgmap-malformed-ca-certificate

# Agent log line 6628:
resource not found  xdsTypeURL=...Secret
  xdsResourceName=cilium-secrets/gateway-conformance-infra-cfgmap-nonexistent-ca-certificate
```

Both SDS secrets are permanently absent because:
1. `nonexistent-ca-certificate` ConfigMap doesn't exist at all
2. `malformed-ca-certificate` ConfigMap exists but the BackendTLSPolicy is rejected (`Accepted: False`), and the `ConfigMapIsReferencedInCiliumGateway` function only syncs ConfigMaps for accepted policies

---

## 6. Envoy Behavior: The 30-Second Window

### 6.1 initial_fetch_timeout

The SDS secret config in the cluster definition includes `initial_fetch_timeout: 30 seconds`:

```
sds_config {
  api_config_source { api_type: GRPC ... }
  initial_fetch_timeout { seconds: 30 }
  resource_api_version: V3
}
```

This timeout governs how long Envoy waits for the initial SDS response before considering the secret definitively unavailable. During this 30-second window, the cluster is in a "warming" state with respect to its TLS validation context.

### 6.2 Observed Behavior Pattern

The test log shows the exact pattern across all three failure runs:

**`nonexistent-ca-certificate-ref` subtest (always FAILS in flaky runs):**

First request at `05:57:13.977` (T+200ms after cluster creation). Every request for 30 seconds returns:

```
HTTP/1.1 400 Bad Request
Server: envoy
X-Envoy-Upstream-Service-Time: 0

<html>
<head><title>400 The plain HTTP request was sent to HTTPS port</title></head>
<body>
<center><h1>400 Bad Request</h1></center>
<center>The plain HTTP request was sent to HTTPS port</center>
</body>
</html>
```

Key evidence:
- `X-Envoy-Upstream-Service-Time: 0` proves Envoy forwarded the request to the backend (not a local error)
- The response body is from the TLS backend pod (nginx) receiving plaintext on its HTTPS port
- This persists for exactly 30 seconds (the `initial_fetch_timeout`)

**`malformed-ca-certificate-ref` subtest (always PASSES in flaky runs):**

First request at `05:57:43.984` (~30.2 seconds after cluster creation). First attempt returns 400, but the second attempt at `05:57:44.990` returns:

```
HTTP/1.1 503 Service Unavailable
Connection: close
Content-Type: text/plain
Server: envoy

upstream connect error or disconnect/reset before headers.
reset reason: remote connection failure,
transport failure reason: TLS error: Secret is not supplied by SDS
```

The 503 with "TLS error: Secret is not supplied by SDS" proves Envoy is now **attempting TLS** (not forwarding plaintext) and correctly failing because the SDS secret doesn't exist.

### 6.3 Timing Correlation

| Event | Timestamp | Delta from Cluster Push |
|-------|-----------|------------------------|
| Clusters pushed to Envoy xDS | `05:57:13.936` | T+0s |
| SDS "resource not found" | `05:57:14.043` | T+0.1s |
| First 400 (nonexistent path) | `05:57:13.977` | T+0.04s |
| Last 400 (nonexistent path) | `05:57:43.xxx` | T+~30s |
| **`initial_fetch_timeout` expires** | **~05:57:43.936** | **T+30s** |
| First 400 (malformed path) | `05:57:43.984` | T+30.05s |
| First 503 (malformed path) | `05:57:44.990` | T+31.05s |

The transition from 400 to 503 aligns precisely with the 30-second `initial_fetch_timeout`.

### 6.4 Results Across All Three Failure Runs

| Run | Nonexistent Subtest | Malformed Subtest |
|-----|-------------------|------------------|
| run_2 | 400 for 30s (**FAIL**) | 400 then 503 after 1s (**PASS**) |
| run_56 | 404 then 400 for 30s (**FAIL**) | 400 then 503 after 1s (**PASS**) |
| run_107 | 404 then 400 for 30s (**FAIL**) | 400 then 503 after 1s (**PASS**) |

The pattern is consistent: the `nonexistent` subtest always fails because its 30-second timeout falls entirely within the `initial_fetch_timeout` window. The `malformed` subtest always passes because it starts after the `initial_fetch_timeout` has expired.

---

## 7. Complete Failure Sequence (run_2)

```
T+0ms     (05:57:13.777)  Test creates HTTPRoute
T+8ms     (05:57:13.785)  Operator: Reconciling Gateway (triggered by HTTPRoute)
T+15ms    (05:57:13.792)  Operator: List BackendTLSPolicies → finds 0
T+31ms    (05:57:13.808)  CEC Gen 2: routes → direct_response:500 (safe)
T+48ms    (05:57:13.825)  Reconciliation 1 succeeds
T+48ms    (05:57:13.825)  Operator: Reconciling Gateway (triggered by Service)
T+61ms    (05:57:13.838)  BackendTLSPolicy nonexistent created (too late for this reconciliation)
T+69ms    (05:57:13.846)  Operator: Backend TLS check → TLS:<nil> (no policy found)
T+74ms    (05:57:13.851)  BackendTLSPolicy malformed created
T+82ms    (05:57:13.859)  ConfigMap malformed-ca-certificate created
T+84ms    (05:57:13.861)  CEC Gen 3: clusters WITHOUT transport_socket (DANGEROUS)
T+91ms    (05:57:13.868)  Reconciliation 2: Gateway status update fails (conflict)
T+92ms    (05:57:13.869)  Operator: Reconciling Gateway (retry, policies=2 now)
T+104ms   (05:57:13.881)  Operator: "Got a match for valid BTLSP on all ports"
T+120ms   (05:57:13.897)  CEC Gen 4: clusters WITH transport_socket + SDS refs
T+159ms   (05:57:13.936)  Agent pushes clusters to Envoy xDS cache
T+200ms   (05:57:13.977)  First test request → HTTP 400 (plaintext forwarded)
T+266ms   (05:57:14.043)  SDS responds: resource not found (0 secrets)
T+200ms → T+30s           All requests → HTTP 400 (30 attempts, all fail)
~T+30s    (05:57:43.936)  initial_fetch_timeout expires
T+30.05s  (05:57:43.984)  Malformed subtest first request → 400 (brief transition)
T+31s     (05:57:44.990)  Malformed subtest second request → 503 "Secret not supplied by SDS"
T+31s+                    Malformed subtest passes
```

---

## 8. Why Only ~5% Failure Rate

The race depends on whether the operator's reconciliation triggered by the HTTPRoute **runs and completes a CEC update** before the BackendTLSPolicies are created. Two scenarios:

### When it fails (~5%):

1. The operator is fast enough to complete reconciliation 2 (Services exist, policies don't) and persist a non-TLS CEC to Kubernetes
2. The Cilium agent receives and processes this intermediate CEC
3. Envoy gets clusters without TLS transport sockets
4. The subsequent CEC update (Gen 4) adds TLS, but the SDS secret can't be resolved
5. Envoy's `initial_fetch_timeout: 30s` creates a 30-second window where TLS behavior is undefined
6. During this window, Envoy forwards plaintext to the TLS backend → 400

### When it succeeds (~95%):

1. The operator's reconciliation is slower, OR all resources are created before the operator lists them
2. The operator's `List BackendTLSPolicies` returns the policies → TLS is configured from the first relevant CEC
3. OR the intermediate CEC states are coalesced by the Kubernetes informer or agent pipeline so that only the final TLS-enabled CEC reaches Envoy
4. The cluster has TLS from the start → Envoy correctly returns 503 from the first request

The ~5% rate reflects how often the operator reconciliation "wins" the ~61ms race window between HTTPRoute and BackendTLSPolicy creation. Factors that influence this:
- **API server latency**: Faster API server = operator processes events faster = more likely to win the race
- **Controller queue depth**: Fewer items in the queue = faster reconciliation
- **Node load**: Affects scheduling of goroutines and controller-runtime event processing
- **Informer cache sync timing**: Whether the informer cache reflects the new resources at List time

---

## 9. Design Issue

The fundamental issue is in `gateway_reconcile.go`: **`btlspMap` is built from a point-in-time `List` of BackendTLSPolicies, and the same `btlspMap` is used for CEC generation.** When the operator reconciles before all resources exist, backends are configured without TLS, and this non-TLS configuration is written to the CEC.

The code path:

```
HTTPRoute created
  → controller enqueues Gateway for reconciliation
  → reconciler runs
    → List BackendTLSPolicies → EMPTY (not created yet)
    → btlspMap = {} (empty)
    → addBackendTLSDetails() → TLS:<nil> (no policy found)
    → withTLSOrigination(nil) → no transport_socket
    → CEC written with plaintext cluster
```

There is no mechanism to:
1. Detect that a backend has `appProtocol: HTTPS` but no BackendTLSPolicy (fail-closed)
2. Debounce reconciliation to wait for related resources
3. Prevent intermediate CECs with non-TLS clusters from being persisted

---

## 10. Proposed Fixes

### Option A: Fail-closed for HTTPS backends without TLS config

In the ingestion layer, when a backend service has `appProtocol: HTTPS` and no BackendTLSPolicy is found in `btlspMap`, treat the backend as unresolvable and use a `direct_response: 500` instead of routing to the cluster without TLS. This matches the existing behavior when a backend Service doesn't exist.

### Option B: Reconciliation guard

Skip CEC updates when BackendTLSPolicies are expected but not yet observed. Could use the HTTPRoute's backend service `appProtocol` to determine that a BackendTLSPolicy should exist.

### Option C: Always add TLS for HTTPS appProtocol

Ensure the cluster always has a TLS transport socket when the backend service has `appProtocol: HTTPS`, even when no BackendTLSPolicy is found. The cluster would fail with a TLS error (503) rather than forwarding plaintext (400).

---

## 11. Remaining Gaps

While the RCA explains the mechanism with strong evidence from the captured logs, there is one area where the evidence is strong but indirect:

**Envoy's exact behavior during the `initial_fetch_timeout` window**: The 30-second correlation between the timeout value and the 400-to-503 transition is very strong circumstantial evidence. However, the captured Envoy proxy logs don't include connection-level debug output that would show exactly how Envoy handles a cluster with TLS + unresolvable SDS secret during the warming period. To definitively confirm:

1. Enable Envoy connection-level debug logging (`--component-log-level connection:debug,upstream:debug`)
2. Use Envoy's admin interface (`/clusters` endpoint) to inspect cluster warming state during the test
3. Test with a different `initial_fetch_timeout` value to confirm the transition timing changes accordingly
