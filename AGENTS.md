# Project Agent Notes

## Purpose

This repo reproduces and validates a Linkerd HTTP/2 client response metadata/header limit bug.

Core signal:

- Stock affected proxy: 22 KiB meshed HTTP/gRPC cases fail.
- Fixed/custom proxy: all HTTP and gRPC rows pass.

## Prerequisites

Required local tools:

- Docker running
- `k3d`
- `kubectl`
- `helm`
- `make`
- `shellcheck` for script checks

Useful checks before long runs:

```bash
docker info >/dev/null
shellcheck scripts/*.sh
bash -n scripts/*.sh
```

## Clean environment setup

Create a fresh disposable k3d cluster and install Linkerd edge:

```bash
make clean
make setup
```

`make clean` deletes:

- k3d cluster `linkerd-header-repro`
- local gRPC repro image `linkerd-grpc-header-repro:local`
- local Linkerd CLI install under `.bin/linkerd2`

It does **not** delete `.build/`, so a previously built `.build/linkerd2-proxy` checkout/binary survives clean test runs.

## Stock proxy repro run

Run against stock Linkerd installed by `make setup`:

```bash
make test
```

Important: `make test` is written as a **fixed-proxy validation** suite. On affected stock Linkerd versions, it should exit nonzero because the 22 KiB repro rows fail. That is expected when proving the bug exists.

Expected stock affected signal:

| Variation | Expected stock result |
|---|---|
| HTTP 12k baseline | PASS |
| HTTP 22k repro | FAIL, meshed `/large` returns 502 |
| HTTP 22k opaque | PASS |
| gRPC 8k baseline | PASS |
| gRPC 22k repro | FAIL, meshed client gets `Internal` / missing trailers |
| gRPC 22k opaque | FAIL for meshed side; unmeshed control passes |

If you need the command to continue for inspection despite expected failures:

```bash
make test || true
```

## Custom proxy validation from `.build`

Use this when `.build/linkerd2-proxy` already contains a built proxy binary:

```bash
./scripts/build-proxy-image.sh
make deploy-proxy \
  PROXY_IMAGE=localhost/linkerd/proxy:fix-15199-local \
  PROXY_VERSION=fix-15199-local
make test PROXY_VERSION=fix-15199-local
```

Expected fixed/custom result: all six rows PASS.

Recent verified result with image built from `.build`:

| Area | Result |
|---|---|
| HTTP 12k baseline | PASS |
| HTTP 22k repro | PASS |
| HTTP 22k opaque | PASS |
| gRPC 8k baseline | PASS |
| gRPC 22k repro | PASS |
| gRPC 22k opaque | PASS |

The test log from the last custom run was saved at:

```text
.build/custom-proxy-suite.log
```

## Full clean custom-proxy run

From a clean cluster, reusing an existing `.build/linkerd2-proxy` binary:

```bash
make clean
make setup
./scripts/build-proxy-image.sh
make deploy-proxy \
  PROXY_IMAGE=localhost/linkerd/proxy:fix-15199-local \
  PROXY_VERSION=fix-15199-local
make test PROXY_VERSION=fix-15199-local
```

If the proxy binary does not exist yet, build it first:

```bash
./scripts/build-custom-proxy.sh
```

That cross-compiles for `linux/arm64` in the Linkerd dev container and then packages the image. This matches k3d on Apple Silicon. On amd64 Linux hosts, adjust the target in `scripts/build-custom-proxy.sh`.

## Important environment variables

| Variable | Default | Use |
|---|---|---|
| `K3D_CLUSTER` | `linkerd-header-repro` | k3d cluster name |
| `LINKERD_VERSION` | `edge-26.5.3` | Linkerd CLI/control-plane version for setup |
| `GRPC_REPRO_IMAGE` | `linkerd-grpc-header-repro:local` | gRPC repro image built/imported by tests |
| `TEST_TIMEOUT_SECONDS` | `90` | Per-probe timeout before a row is marked FAIL |
| `PROXY_IMAGE` | `localhost/linkerd/proxy:fix-15199-local` | Custom proxy image to package/deploy |
| `PROXY_VERSION` | unset unless supplied | Proxy version annotation for injected pods |
| `PROXY_HTTP2_MAX_HEADER_LIST_SIZE` | `131072` | Custom proxy HTTP/2 client header-list size env var |
| `PROXY_BASE_IMAGE` | `ghcr.io/linkerd/proxy:edge-26.5.3` | Base image for `build-proxy-image.sh` |

Do not set `PROXY_VERSION` for stock repro runs unless the corresponding image/version is installed in the cluster. For custom runs, pass the same `PROXY_VERSION` to both `make deploy-proxy` and `make test`.

## Verify custom proxy is active

Linkerd injects `linkerd-proxy` under `spec.initContainers` in this environment.

```bash
kubectl -n linkerd-header-repro-22k get pod \
  -l app.kubernetes.io/component=meshed-client \
  -o jsonpath='{.items[0].metadata.annotations.linkerd\.io/proxy-version}{"\n"}'

kubectl -n linkerd-header-repro-22k get pod \
  -l app.kubernetes.io/component=meshed-client \
  -o jsonpath='{.items[0].spec.initContainers[?(@.name=="linkerd-proxy")].image}{"\n"}'

kubectl -n linkerd-header-repro-22k get pod \
  -l app.kubernetes.io/component=meshed-client \
  -o jsonpath='{range .items[0].spec.initContainers[?(@.name=="linkerd-proxy")].env[*]}{.name}={.value}{"\n"}{end}' \
  | rg MAX_HEADER
```

Expected custom values:

```text
fix-15199-local
localhost/linkerd/proxy:fix-15199-local
LINKERD2_PROXY_OUTBOUND_CONNECT_HTTP2_MAX_HEADER_LIST_SIZE=131072
LINKERD2_PROXY_INBOUND_CONNECT_HTTP2_MAX_HEADER_LIST_SIZE=131072
```

## Common gotchas

- `make test` takes time on broken stock proxies because failing rows wait for `TEST_TIMEOUT_SECONDS` before being marked FAIL.
- If stock 22 KiB rows unexpectedly pass, verify you did not leave `PROXY_VERSION` set or custom workloads running.
- If custom rows unexpectedly fail, verify pod annotation/image/env vars with the commands above.
- Use `scripts/build-proxy-image.sh` only when `.build/linkerd2-proxy/target/aarch64-unknown-linux-gnu/release/linkerd2-proxy` already exists.
- Use `scripts/build-custom-proxy.sh` when you need to compile the proxy from source.

## Cleanup

Delete only repro namespaces:

```bash
make clean-repro
```

Delete the whole disposable environment:

```bash
make clean
```
