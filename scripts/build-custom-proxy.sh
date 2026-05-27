#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
proxy_src="${root_dir}/.build/linkerd2-proxy"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -d "${proxy_src}/.git" ]] || die "missing ${proxy_src}; clone the PR branch first"

echo "==> Building linkerd2-proxy for linux/arm64"
docker run --rm --platform linux/amd64 --entrypoint /bin/sh \
  -v "${proxy_src}:/src" \
  -w /src \
  ghcr.io/linkerd/dev:v48-rust \
  -c '
set -e
export PATH=/usr/local/cargo/bin:/usr/local/bin:$PATH
export RUSTFLAGS="-D warnings -A deprecated --cfg tokio_unstable"
export CARGO_NET_RETRY=10

apt-get update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  binutils-aarch64-linux-gnu \
  gcc-aarch64-linux-gnu \
  libc6-dev-arm64-cross \
  >/dev/null

just fetch
just arch=arm64 profile=release build
'

echo "==> Packaging proxy image"
PROXY_IMAGE="${PROXY_IMAGE:-localhost/linkerd/proxy:fix-15199-local}" \
  "${root_dir}/scripts/build-proxy-image.sh"
