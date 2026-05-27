#!/usr/bin/env bash
set -euo pipefail

namespace="${1:-linkerd-header-repro}"
release="${2:-linkerd-header-repro}"
header_bytes="${3:-22000}"

kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install "${release}" "$(dirname "$0")/../chart" \
  --namespace "${namespace}" \
  --set "server.largeHeaderBytes=${header_bytes}" \
  --wait

cat <<EOF
Installed ${release} in ${namespace} with server.largeHeaderBytes=${header_bytes}.

Watch logs:
  kubectl -n ${namespace} logs deploy/${release}-meshed-client -c curl -f
  kubectl -n ${namespace} logs deploy/${release}-unmeshed-client -c curl -f
EOF
