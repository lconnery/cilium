# RCA: Flaky Gateway API Conformance Test `BackendTLSPolicyInvalidCACertificateRef`

## Executive Summary
The Gateway API conformance test `BackendTLSPolicyInvalidCACertificateRef` periodically fails (around 3-5% of the time) returning a `400 Bad Request` instead of the expected `500`, `502`, or `503` status codes.

The root cause is a race condition between the Cilium Operator's processing of Kubernetes informer cache events and Envoy's cluster warming mechanism. When resources are created nearly simultaneously, there is a narrow window where the operator processes the `HTTPRoute` and `Service` without the associated invalid `BackendTLSPolicy`. This results in the operator pushing a valid, active *plaintext* Envoy cluster. Milliseconds later, when the invalid `BackendTLSPolicy` is processed, the operator pushes a new *TLS-enabled* cluster configuration. Because the CA cert is invalid/missing, Envoy's SDS (Secret Discovery Service) fails to provide the secret, causing the new TLS cluster to get stuck in the `Warming` state. Consequently, Envoy continues routing traffic to the previously known `Active` plaintext cluster. The test requests hit the HTTPS backend via plaintext, causing the backend to reject them with a `400 Bad Request`.

## Expected Behavior vs Actual Behavior

**Gateway API Specification:**
"If a BackendTLSPolicy is accepted but the configuration is invalid (for example, referring to a non-existent Secret or ConfigMap), the Gateway must route traffic to the backend, but return a 500 status code for any requests routed to it."

**Test Expectation:**
The test issues HTTP GET requests to a backend targeted by an invalid `BackendTLSPolicy` (e.g. `malformed-ca-certificate-ref` or `nonexistent-ca-certificate-ref`) and expects a `5xx` response code.

**Actual Behavior:**
The test receives a `400 Bad Request` with the body: `Client sent an HTTP request to an HTTPS server.`

## Detailed Root Cause Analysis

### 1. The Race Condition: Resource Creation and Cache Synchronization
The conformance test applies all necessary resources (`HTTPRoute`, `Service`, `BackendTLSPolicy`) nearly simultaneously. 

*Test Log Evidence:*
```text
2026-01-27T10:42:44.417Z: Creating backendtlspolicy-invalid-ca-certificate-ref HTTPRoute
2026-01-27T10:42:44.423Z: Creating backendtlspolicy-nonexistent-ca-certificate-ref-test Service
...
2026-01-27T10:42:44.440Z: Creating nonexistent-ca-certificate-ref BackendTLSPolicy
```

Because Kubernetes Informer caches process events asynchronously, there are two possible paths:

**Path A (The ~95% Pass Case):**
The `BackendTLSPolicy` arrives in the operator's cache before or at the same time as the `HTTPRoute` and `Service`. The operator generates the Envoy `Cluster` **with TLS** on the very first attempt. Envoy attempts to warm it, fails to find the SDS secret, and the cluster stays warming. Because there is no active cluster, Envoy drops the request returning `503 Service Unavailable`, passing the test.

**Path B (The ~5% Fail Case):**
The `HTTPRoute` and `Service` arrive in the cache slightly before the `BackendTLSPolicy`. The following sequence ensues.

### 2. First Cluster Generation (Plaintext -> Active)
Because the `BackendTLSPolicy` is not yet in the cache, the `addBackendTLSDetails` function (in `operator/pkg/model/ingestion/gateway.go`) finds no relevant policies. The operator generates the Envoy `Cluster` configuration **without** TLS. 
Because this plaintext cluster has no SDS dependencies, Envoy receives the config and immediately transitions the cluster to the **Active** state.

### 3. Second Cluster Generation (TLS -> Warming)
Milliseconds later, the `BackendTLSPolicy` syncs to the cache and triggers another reconcile. 

The operator evaluates the `BackendTLSPolicy` validity:
```go
// operator/pkg/gateway-api/gateway_reconcile.go ~line 1169
inputLogger.Debug("Validating BackendTLSPolicy spec")
valid, err := input.ValidateSpec(ctx, inputLogger, currentGatewayRef)
```
`ValidateSpec` correctly identifies that the CA cert is missing and updates the policy's status to `ResolvedRefs=False`. **However, it does not remove the policy from `collection.Valid` (the `btlspMap` passed to the ingestion package).**

The ingestion package processes the HTTPRoute and blindly attaches the TLS settings from the invalid policy to the Envoy model:
```go
// operator/pkg/model/ingestion/gateway.go
func addBackendTLSDetails(log *slog.Logger, be model.Backend, svc *corev1.Service, btlspMap helpers.BackendTLSPolicyServiceMap) model.Backend {
    // ... finds the policy in the map ...
    be.TLS = &model.BackendTLSOrigination{
        SNI: string(btlsp.Spec.Validation.Hostname),
    }
    // ...
```
The operator pushes the updated cluster configuration (now requiring TLS via an Envoy TransportSocket) to Envoy.

### 4. Envoy SDS Failure and Fallback
Envoy receives the cluster update and attempts to "warm" it. The `TransportSocket` configuration mandates an SDS (Secret Discovery Service) secret fetch for the CA Certificate. Because the CA ConfigMap is invalid/missing, the Cilium `secretsync` controller never creates the secret.

Because Envoy cannot fetch the SDS secret, the new TLS-enabled cluster **gets stuck in the `Warming` state**. 

When an updated cluster is stuck warming, **Envoy continues to route traffic to the last known `Active` cluster.**

### 5. The Failing Request
The test sends its HTTP request:
```http
< GET /backendtlspolicy-nonexistent-ca-certificate-ref HTTP/1.1
< Host: abc.example.com
```

Envoy routes the request to the only **Active** cluster it has: the plaintext one generated in Step 2. The traffic hits the test's HTTPS backend server in plaintext, causing the backend to reject it:
```http
< HTTP/1.1 400 Bad Request
< Client sent an HTTP request to an HTTPS server.
```

## Why the Flake Rate is Low
The flake relies entirely on the `HTTPRoute` and `Service` hitting the operator's cache fast enough to establish an active plaintext cluster in Envoy *before* the `BackendTLSPolicy` triggers the TLS update. Because the test framework applies the resources simultaneously, this precise timing window only aligns ~3-5% of the time. 

If an artificial delay (e.g. `sleep 2`) is introduced in the test script between the creation of the Gateway/Routes/Services and the creation of the `BackendTLSPolicy`, this race condition can be reproduced nearly 100% of the time.

## Recommended Fix Direction
The fundamental issue is that the operator passes known-invalid `BackendTLSPolicy` objects into the Envoy translation layer, relying on organic Envoy SDS warming failures to generate `503` errors. 

When `ValidateSpec` evaluates a `BackendTLSPolicy` as invalid (returning `false`), the operator should actively prevent that invalid configuration from manifesting as a valid route or a warming cluster. 
The Gateway API states a `500` status code should be returned. The operator's HTTPRoute translation logic already supports a `DirectResponse: 500` fallback when no valid backends are found:

```go
// operator/pkg/model/ingestion/gateway.go
var dr *model.DirectResponse
if len(bes) == 0 {
    dr = &model.DirectResponse{
        StatusCode: 500,
    }
}
```

The operator should either exclude the invalid backend entirely (triggering the `DirectResponse: 500` block above), or explicitly mutate the route to return a 500 Direct Response when the targeted `BackendTLSPolicy` is invalid.