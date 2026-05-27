#!/usr/bin/env bash
set -euo pipefail

cluster="${K3D_CLUSTER:-linkerd-header-repro}"
linkerd_bin="${LINKERD_BIN:-./.bin/linkerd2/bin/linkerd}"
proxy_image="${PROXY_IMAGE:-localhost/linkerd/proxy:fix-15199-local}"
header_list_size="${PROXY_HTTP2_MAX_HEADER_LIST_SIZE:-131072}"
proxy_version="${PROXY_VERSION:-${proxy_image##*:}}"
context="k3d-${cluster}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -x "${linkerd_bin}" ]] || die "Linkerd CLI not found at ${linkerd_bin}; run make setup first"
docker image inspect "${proxy_image}" >/dev/null 2>&1 || die "proxy image not found: ${proxy_image}"

kubectl config use-context "${context}" >/dev/null

echo "==> Importing ${proxy_image} into k3d cluster ${cluster}"
k3d image import "${proxy_image}" -c "${cluster}"

image_repo="${proxy_image%:*}"
image_tag="${proxy_image##*:}"

echo "==> Upgrading Linkerd control plane with custom proxy ${image_repo}:${image_tag}"
"${linkerd_bin}" upgrade --crds | kubectl apply -f -
"${linkerd_bin}" upgrade \
  --set "proxy.image.name=${image_repo}" \
  --set-string "proxy.image.version=${image_tag}" \
  --set "proxy.image.pullPolicy=IfNotPresent" \
  --set "proxy.additionalEnv[0].name=LINKERD2_PROXY_OUTBOUND_CONNECT_HTTP2_MAX_HEADER_LIST_SIZE" \
  --set-string "proxy.additionalEnv[0].value=${header_list_size}" \
  --set "proxy.additionalEnv[1].name=LINKERD2_PROXY_INBOUND_CONNECT_HTTP2_MAX_HEADER_LIST_SIZE" \
  --set-string "proxy.additionalEnv[1].value=${header_list_size}" \
  | kubectl apply -f -

kubectl -n linkerd rollout status deploy/linkerd-destination --timeout=240s
kubectl -n linkerd rollout status deploy/linkerd-identity --timeout=240s
kubectl -n linkerd rollout status deploy/linkerd-proxy-injector --timeout=240s

echo "==> Restarting repro workloads so they pick up the new proxy image"
for ns in \
  linkerd-header-repro-12k \
  linkerd-header-repro-22k \
  linkerd-header-repro-opaque \
  linkerd-grpc-repro-8k \
  linkerd-grpc-repro-22k \
  linkerd-grpc-repro-opaque; do
  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    continue
  fi

  while IFS= read -r deploy; do
    [[ -n "${deploy}" ]] || continue
    kubectl -n "${ns}" annotate "${deploy}" \
      "config.linkerd.io/proxy-version=${proxy_version}" \
      --overwrite >/dev/null
    kubectl -n "${ns}" annotate "${deploy}" \
      "linkerd.io/proxy-version-" >/dev/null 2>&1 || true
    kubectl -n "${ns}" rollout restart "${deploy}" >/dev/null
  done < <(kubectl -n "${ns}" get deploy -o name)
done

cat <<EOF

Custom proxy deployed.

Proxy image: ${proxy_image}
Proxy version annotation: ${proxy_version}
HTTP/2 client max header list size: ${header_list_size}

Verify a meshed proxy pod is using the new image:
  kubectl -n linkerd-header-repro-22k get pod -l app.kubernetes.io/component=meshed-client \\
    -o jsonpath='{.items[0].spec.initContainers[?(@.name=="linkerd-proxy")].image}{"\\n"}'

Run tests:
  make test
EOF
