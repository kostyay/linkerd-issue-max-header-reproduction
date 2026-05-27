#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
proxy_src="${root_dir}/.build/linkerd2-proxy"
proxy_bin="${proxy_src}/target/aarch64-unknown-linux-gnu/release/linkerd2-proxy"
base_image="${PROXY_BASE_IMAGE:-ghcr.io/linkerd/proxy:edge-26.5.3}"
proxy_image="${PROXY_IMAGE:-localhost/linkerd/proxy:fix-15199-local}"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "${proxy_bin}" ]] || die "built proxy binary not found at ${proxy_bin}; run scripts/build-custom-proxy.sh first"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cp "${proxy_bin}" "${tmpdir}/linkerd2-proxy"
chmod +x "${tmpdir}/linkerd2-proxy"

cat >"${tmpdir}/Dockerfile" <<EOF
FROM ${base_image}
COPY linkerd2-proxy /usr/lib/linkerd/linkerd2-proxy
EOF

echo "==> Building ${proxy_image} from ${base_image}"
docker build --platform linux/arm64 -t "${proxy_image}" "${tmpdir}"

echo "Built ${proxy_image}"
