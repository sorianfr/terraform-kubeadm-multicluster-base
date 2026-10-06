#!/bin/bash
# Uninstall Istio from all clusters BEFORE terraform destroy.
# Removes LoadBalancer Services/ENIs that otherwise block VPC/IGW deletion.
#
# Usage (from this repo):
#   ./uninstall_istio.sh
#   ./uninstall_istio.sh ec2-xx-xx-xx-xx.compute-1.amazonaws.com
#
# Or run directly on the bastion:
#   ./uninstall_istio.sh --local

set -euo pipefail

SSH_KEY="./k8s-key.pem"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.0}"

run_uninstall() {
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" ubuntu@"$BASTION_HOST" \
  "ISTIO_VERSION=${ISTIO_VERSION}" bash <<'EOF'
set -euo pipefail

ISTIO_VERSION="${ISTIO_VERSION:-1.28.0}"
CONTEXTS=(cluster1 cluster2)

if [[ -x "${HOME}/istio-${ISTIO_VERSION}/bin/istioctl" ]]; then
  export PATH="${HOME}/istio-${ISTIO_VERSION}/bin:${PATH}"
fi

if ! command -v istioctl >/dev/null 2>&1; then
  echo "istioctl not found. Expected in PATH or ~/istio-${ISTIO_VERSION}/bin"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found"
  exit 1
fi

if [[ -f "${HOME}/.kube/config" ]]; then
  export KUBECONFIG="${HOME}/.kube/config"
fi

for ctx in "${CONTEXTS[@]}"; do
  echo "==> Uninstalling Istio from context: ${ctx}"
  if ! kubectl config get-contexts "${ctx}" >/dev/null 2>&1; then
    echo "    context ${ctx} not found, skipping"
    continue
  fi

  istioctl --context "${ctx}" uninstall --purge -y || true

  kubectl --context "${ctx}" -n istio-system delete svc \
    istio-ingressgateway istio-eastwestgateway \
    --ignore-not-found || true

  kubectl --context "${ctx}" delete namespace istio-system \
    --ignore-not-found --wait=false || true
done

echo "==> Waiting for AWS Load Balancers/ENIs to release..."
sleep 45
echo "Done. You can now run: terraform destroy"
EOF
}

run_uninstall_local() {
set -euo pipefail

ISTIO_VERSION="${ISTIO_VERSION:-1.28.0}"
CONTEXTS=(cluster1 cluster2)

if [[ -x "${HOME}/istio-${ISTIO_VERSION}/bin/istioctl" ]]; then
  export PATH="${HOME}/istio-${ISTIO_VERSION}/bin:${PATH}"
fi

if ! command -v istioctl >/dev/null 2>&1; then
  echo "istioctl not found. Expected in PATH or ~/istio-${ISTIO_VERSION}/bin"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found"
  exit 1
fi

if [[ -f "${HOME}/.kube/config" ]]; then
  export KUBECONFIG="${HOME}/.kube/config"
fi

for ctx in "${CONTEXTS[@]}"; do
  echo "==> Uninstalling Istio from context: ${ctx}"
  if ! kubectl config get-contexts "${ctx}" >/dev/null 2>&1; then
    echo "    context ${ctx} not found, skipping"
    continue
  fi

  istioctl --context "${ctx}" uninstall --purge -y || true

  kubectl --context "${ctx}" -n istio-system delete svc \
    istio-ingressgateway istio-eastwestgateway \
    --ignore-not-found || true

  kubectl --context "${ctx}" delete namespace istio-system \
    --ignore-not-found --wait=false || true
done

echo "==> Waiting for AWS Load Balancers/ENIs to release..."
sleep 45
echo "Done. You can now run: terraform destroy"
}

if [[ "${1:-}" == "--local" ]]; then
  run_uninstall_local
  exit 0
fi

BASTION_HOST="${1:-}"
if [[ -z "${BASTION_HOST}" ]]; then
  if command -v terraform >/dev/null 2>&1; then
    BASTION_HOST="$(terraform output -raw bastion_public_dns 2>/dev/null || true)"
  fi
fi

if [[ -z "${BASTION_HOST}" ]]; then
  echo "Usage: $0 <bastion-public-dns>"
  echo "   or: $0 --local   # when already on the bastion"
  echo "   or: ensure 'terraform output bastion_public_dns' works"
  exit 1
fi

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "SSH key not found: ${SSH_KEY}"
  exit 1
fi

echo "Uninstalling Istio via bastion ${BASTION_HOST}..."
run_uninstall
