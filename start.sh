#!/bin/bash

KIND_VERSION="v0.31.0"
KIND_K8S_IMAGE="quay.io/cilium/kindest-node:v1.35.0@sha256:a36285a50bb7ee33d44b6d7938dca10e34f8a9294873ae4b0b04f9d21619d44c"
KIND_K8S_VERSION="v1.35.0"

kind create cluster --name chart-testing --image "${KIND_K8S_IMAGE}" --config .github/kind-config.yaml

gateway_api_version=$(grep -m 1 "sigs.k8s.io/gateway-api" go.mod | awk '{print $2}' | awk -F'-' '{print (NF>2)?$NF:$0}')

kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gateway_api_version/config/crd/experimental/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gateway_api_version/config/crd/experimental/gateway.networking.k8s.io_gateways.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gateway_api_version/config/crd/experimental/gateway.networking.k8s.io_httproutes.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gateway_api_version/config/crd/experimental/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gateway_api_version/config/crd/experimental/gateway.networking.k8s.io_grpcroutes.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gateway_api_version/config/crd/experimental/gateway.networking.k8s.io_backendtlspolicies.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$gateway_api_version/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml

kubectl wait --for condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=5m
kubectl wait --for condition=Established crd/gateways.gateway.networking.k8s.io --timeout=5m
kubectl wait --for condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=5m
kubectl wait --for condition=Established crd/tlsroutes.gateway.networking.k8s.io --timeout=5m
kubectl wait --for condition=Established crd/grpcroutes.gateway.networking.k8s.io --timeout=5m
kubectl wait --for condition=Established crd/referencegrants.gateway.networking.k8s.io --timeout=5m
kubectl wait --for condition=Established crd/backendtlspolicies.gateway.networking.k8s.io --timeout=5m

cilium install \
  --chart-directory=./install/kubernetes/cilium \
  --helm-set=kubeProxyReplacement=true \
  --helm-set=gatewayAPI.enabled=true \
  --helm-set=l2announcements.enabled=true \
  --helm-set=debug.enabled=true \
  --helm-set=debug.verbose=envoy

cilium status --wait

KIND_NET_CIDR=$(docker network inspect kind -f '{{json .IPAM.Config}}' | jq -r '.[] | select(.Subnet | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+")) | .Subnet')
PREFIX=$(echo $KIND_NET_CIDR | cut -d. -f1,2,3)
GATEWAY_API_CONFORMANCE_USABLE_NETWORK_ADDRESSES="$PREFIX.206"
GATEWAY_API_CONFORMANCE_UNUSABLE_NETWORK_ADDRESSES="$PREFIX.216"
export GATEWAY_API_CONFORMANCE_TESTS=1

# Extract the first 3 octets (e.g., "192.168.8") and append a safe /28 range
PREFIX=$(echo $KIND_NET_CIDR | cut -d. -f1,2,3)
LB_CIDR="$PREFIX.240/28"

echo "Kind CIDR is: $KIND_NET_CIDR"
echo "LoadBalancer CIDR is: $LB_CIDR"

cat << EOF | kubectl apply -f -
apiVersion: "cilium.io/v2"
kind: CiliumLoadBalancerIPPool
metadata:
  name: "pool"
spec:
  blocks:
    - cidr: "$LB_CIDR"
---
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
  name: l2policy
spec:
  loadBalancerIPs: true
  interfaces:
    - eth0
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
EOF

EXEMPT_FEATURES="HTTPRouteParentRefPort,MeshConsumerRoute"
SKIPPED_TESTS=""
GATEWAY_TEST_FLAGS="--gateway-class cilium --debug --all-features --allow-crds-mismatch --cleanup-base-resources=false"
GATEWAY_TEST_FLAGS="$GATEWAY_TEST_FLAGS --exempt-features \"$EXEMPT_FEATURES\" -test.skip \"$SKIPPED_TESTS\""

mkdir -p cilium-junits
GATEWAY_API_CONFORMANCE_USABLE_NETWORK_ADDRESSES="$GATEWAY_API_CONFORMANCE_USABLE_NETWORK_ADDRESSES" \
GATEWAY_API_CONFORMANCE_UNUSABLE_NETWORK_ADDRESSES="$GATEWAY_API_CONFORMANCE_UNUSABLE_NETWORK_ADDRESSES" \
GATEWAY_TEST_FLAGS="$GATEWAY_TEST_FLAGS" \
make gateway-api-conformance GATEWAY_API_CONFORMANCE_TEST_NAME="TestConformance/BackendTLSPolicyInvalidCACertificateRef"
