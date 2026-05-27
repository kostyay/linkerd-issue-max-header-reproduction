# Linkerd HTTP/2 Client Response Header Limit Reproduction

Minimal Helm chart that reproduces a Linkerd proxy regression where a meshed client fails to receive a large HTTP/2 response header from a meshed server.

## What this reproduces

A server returns a normal HTTP 200 response with a large response header:

```text
X-Large-Response-Header: <22 KiB of "a">
```

Two clients call it repeatedly:

- `meshed-client`: `linkerd.io/inject: enabled`
- `unmeshed-client`: `linkerd.io/inject: disabled`

Expected behavior on affected Linkerd proxy versions:

- `unmeshed-client` succeeds with HTTP 200.
- `meshed-client` succeeds for `/small` but fails for `/large` with HTTP 502 / `l5d-proxy-error`.

This mirrors the Traefik `forwardAuth` failure mode:

```text
Traefik app -> local Linkerd outbound proxy -> meshed auth-service -> response header >16 KiB
```

## Local k3d reproduction

The Makefile can create a disposable k3d cluster, install Linkerd edge, run the HTTP and gRPC variations, and print a markdown report.

### Prerequisites

- Docker (running)
- `k3d`, `kubectl`, `helm`, `make`
- For custom proxy builds: `git` and enough disk/CPU for a Rust release build (~10–20 minutes on first run)

### End-to-end test run (stock Linkerd proxy)

This flow reproduces the bug against the upstream Linkerd proxy installed by `make setup`:

```bash
make setup
make test
```

`make test` runs:

- HTTP response header checks: 12 KiB baseline, 22 KiB repro, 22 KiB opaque-port workaround.
- gRPC response trailer checks: 8 KiB baseline, 22 KiB repro, 22 KiB opaque server-port control.

It prints a markdown report to stdout. The suite expects a **fixed** proxy (all variations PASS). Against stock affected versions, the 22 KiB cases will **FAIL** in the report — that failure is the repro signal:

| Variation | Expected on stock (broken) |
|---|---|
| HTTP 12k baseline | PASS |
| HTTP 22k repro | FAIL — meshed `/large` returns 502 |
| HTTP 22k opaque | PASS |
| gRPC 8k baseline | PASS |
| gRPC 22k repro | FAIL — meshed client gets Internal, 0 trailer bytes |
| gRPC 22k opaque | FAIL — meshed client still broken; unmeshed control passes |

Use the custom-proxy flow below when validating a fix; all six rows should PASS.

Clean up everything created by the Makefile:

```bash
make clean
```

Useful overrides:

```bash
make setup K3D_CLUSTER=my-repro LINKERD_VERSION=edge-26.5.3
make test K3D_CLUSTER=my-repro TEST_TIMEOUT_SECONDS=120
```

### End-to-end test run (custom linkerd2-proxy build)

Use this flow to validate a fix in a fork or PR branch of [linkerd2-proxy](https://github.com/linkerd/linkerd2-proxy).

**1. Create the cluster (once):**

```bash
make setup
```

**2. Check out the proxy source you want to test:**

The build scripts read from `.build/linkerd2-proxy`. Clone any GitHub repo/branch there:

```bash
rm -rf .build/linkerd2-proxy

# Upstream branch
git clone --branch main --depth 1 \
  https://github.com/linkerd/linkerd2-proxy.git .build/linkerd2-proxy

# PR branch on a fork
git clone --branch fix/15199-client-max-header-list-size --depth 1 \
  https://github.com/wahajahmed010/linkerd2-proxy.git .build/linkerd2-proxy

# Local checkout
git clone /path/to/your/linkerd2-proxy .build/linkerd2-proxy
cd .build/linkerd2-proxy && git checkout your-branch && cd ../..
```

To switch branches later:

```bash
cd .build/linkerd2-proxy
git fetch origin your-branch
git checkout your-branch
cd ../..
```

**3. Build a local proxy image:**

```bash
./scripts/build-custom-proxy.sh
```

This cross-compiles `linkerd2-proxy` for `linux/arm64` inside the Linkerd dev container, then wraps the binary in a Docker image. The default tag is `localhost/linkerd/proxy:fix-15199-local`.

If `.build/linkerd2-proxy` already has a built binary, package it directly without recompiling:

```bash
./scripts/build-proxy-image.sh
```

Use a custom tag if you are testing multiple branches:

```bash
PROXY_IMAGE=localhost/linkerd/proxy:my-branch ./scripts/build-custom-proxy.sh
```

**4. Deploy the custom proxy into k3d:**

```bash
make deploy-proxy \
  PROXY_IMAGE=localhost/linkerd/proxy:my-branch \
  PROXY_VERSION=my-branch
```

`make deploy-proxy`:

- imports the image into k3d
- upgrades the Linkerd control plane to use it
- sets proxy env vars for the HTTP/2 client header limit (see below)
- restarts existing repro workloads and pins them to the custom proxy version

**5. Run the test suite:**

```bash
make test PROXY_VERSION=my-branch
```

Pass the same `PROXY_VERSION` you used in step 4 so newly installed repro pods get `config.linkerd.io/proxy-version` set correctly.

When a fix is working, all six variations should **PASS**, including:

- HTTP 22k repro: meshed `/large` returns **200**
- gRPC 22k repro: meshed client receives **Unauthenticated** and full 22 KiB trailers

**One-liner after clone:**

```bash
make setup && \
  PROXY_IMAGE=localhost/linkerd/proxy:my-branch ./scripts/build-custom-proxy.sh && \
  make deploy-proxy PROXY_IMAGE=localhost/linkerd/proxy:my-branch PROXY_VERSION=my-branch && \
  make test PROXY_VERSION=my-branch
```

### Custom proxy configuration

| Variable | Default | Purpose |
|---|---|---|
| `PROXY_IMAGE` | `localhost/linkerd/proxy:fix-15199-local` | Docker image `repo:tag` built and deployed |
| `PROXY_VERSION` | unset for tests; proxy image tag during deploy | Value for `config.linkerd.io/proxy-version` on repro pods |
| `PROXY_HTTP2_MAX_HEADER_LIST_SIZE` | `131072` | Sets both connect-side HTTP/2 client env vars on injected proxies |
| `PROXY_BASE_IMAGE` | `ghcr.io/linkerd/proxy:edge-26.5.3` | Base image used when packaging the custom binary |

The deploy step sets these proxy env vars (required for PRs that add configurability but keep the 16 KiB default):

```text
LINKERD2_PROXY_OUTBOUND_CONNECT_HTTP2_MAX_HEADER_LIST_SIZE=131072
LINKERD2_PROXY_INBOUND_CONNECT_HTTP2_MAX_HEADER_LIST_SIZE=131072
```

Override the limit:

```bash
make deploy-proxy PROXY_HTTP2_MAX_HEADER_LIST_SIZE=262144
```

### Verify the custom proxy is active

```bash
kubectl config use-context k3d-linkerd-header-repro

kubectl -n linkerd-header-repro-22k get pod \
  -l app.kubernetes.io/component=meshed-client \
  -o jsonpath='{.items[0].metadata.annotations.linkerd\.io/proxy-version}{"\n"}'

kubectl -n linkerd-header-repro-22k get pod \
  -l app.kubernetes.io/component=meshed-client \
  -o jsonpath='{.items[0].spec.initContainers[?(@.name=="linkerd-proxy")].image}{"\n"}'
```

You should see your `PROXY_VERSION` and `PROXY_IMAGE`.

Check the env vars on the proxy sidecar:

```bash
kubectl -n linkerd-header-repro-22k get pod \
  -l app.kubernetes.io/component=meshed-client \
  -o jsonpath='{range .items[0].spec.initContainers[?(@.name=="linkerd-proxy")].env[*]}{.name}={.value}{"\n"}{end}' \
  | rg MAX_HEADER
```

### Build notes

- Source is cloned to `.build/linkerd2-proxy` (gitignored).
- The build targets **linux/arm64**, matching k3d on Apple Silicon. On amd64 Linux hosts, adjust the cross-compilation target in `scripts/build-custom-proxy.sh` if needed.
- Build logs are written to `.build/proxy-build-*.log` when using the manual docker commands from earlier iterations; `build-custom-proxy.sh` prints directly to stdout.
- If compilation fails, common gaps in WIP PRs include missing `max_header_list_size` in `linkerd/proxy/api-resolve/src/pb.rs` and unused imports in `linkerd/app/src/env.rs`.

### Scripts reference

| Script | Purpose |
|---|---|
| `scripts/setup-k3d.sh` | Create k3d cluster, install Linkerd edge (`make setup`) |
| `scripts/test-variations.sh` | Run all HTTP/gRPC variations and print report (`make test`) |
| `scripts/build-custom-proxy.sh` | Build `linkerd2-proxy` from `.build/linkerd2-proxy` and package image |
| `scripts/build-proxy-image.sh` | Package an already-built binary into a Docker image |
| `scripts/deploy-custom-proxy.sh` | Import image, upgrade Linkerd, set env vars, restart repro pods (`make deploy-proxy`) |
| `scripts/install.sh` | Manual single-namespace Helm install (no test matrix) |

## Manual install

Use a namespace where Linkerd injection is available. The chart annotates individual pods, so namespace-wide injection is not required.

```bash
kubectl create namespace linkerd-header-repro || true

helm upgrade --install linkerd-header-repro ./chart \
  --namespace linkerd-header-repro \
  --wait
```

## Observe

```bash
kubectl -n linkerd-header-repro get pods

kubectl -n linkerd-header-repro logs deploy/linkerd-header-repro-server -c server -f
kubectl -n linkerd-header-repro logs deploy/linkerd-header-repro-meshed-client -c curl -f
kubectl -n linkerd-header-repro logs deploy/linkerd-header-repro-unmeshed-client -c curl -f
```

Affected Linkerd versions should show something like this in `meshed-client` logs for `/large`:

```text
< HTTP/1.1 502 Bad Gateway
< l5d-proxy-error: endpoint <pod-ip>:8080: upgraded connection failed with HTTP/2 reset: unable to maintain the header compression context
http_code=502
```

The unmeshed client should show HTTP 200:

```text
< HTTP/1.1 200 OK
< X-Large-Response-Header: aaaaa...
http_code=200
path=/large
header=X-Large-Response-Header
configured_header_value_bytes=22000
```

The meshed client also calls `/small`, which should return HTTP 200. That proves basic service connectivity is working and isolates the failure to response header size.

## Vary the header size

A value below ~16 KiB should pass:

```bash
helm upgrade --install linkerd-header-repro ./chart \
  --namespace linkerd-header-repro \
  --set server.largeHeaderBytes=12000 \
  --wait
```

A value above ~16 KiB should fail on affected versions:

```bash
helm upgrade --install linkerd-header-repro ./chart \
  --namespace linkerd-header-repro \
  --set server.largeHeaderBytes=22000 \
  --wait
```

## Validate current Linkerd proxy version

```bash
kubectl -n linkerd-header-repro get pod \
  -l app.kubernetes.io/component=meshed-client \
  -o jsonpath='{.items[0].spec.initContainers[?(@.name=="linkerd-proxy")].image}{"\n"}'
```

Look for the `cr.l5d.io/linkerd/proxy:<version>` or custom proxy image.

## Expected root cause

This is not a body buffering issue. The response body is tiny.

The failure is response metadata/header handling in the client's Linkerd outbound proxy. Recent Linkerd proxy versions use Hyper 1.x / h2 0.4+, where the HTTP/2 client has a default `max_header_list_size` of 16 KiB. Linkerd exposes server-side HTTP/2 max header list size knobs, but does not expose the corresponding client-side receive limit.

Existing env vars only cover server-side received request headers:

```text
LINKERD2_PROXY_INBOUND_SERVER_HTTP2_MAX_HEADER_LIST_SIZE
LINKERD2_PROXY_OUTBOUND_SERVER_HTTP2_MAX_HEADER_LIST_SIZE
```

They do not raise the HTTP/2 client-side response header decode limit.

## Workaround check: opaque port

To confirm the issue is Linkerd HTTP parsing, set the server port opaque:

```bash
helm upgrade --install linkerd-header-repro ./chart \
  --namespace linkerd-header-repro \
  --set server.podAnnotations.'config\.linkerd\.io/opaque-ports'=8080 \
  --wait
```

If opaque mode is honored, Linkerd should stop parsing HTTP/2 on this hop and the large response header should pass. This is a workaround, not the desired permanent fix, because it loses Linkerd L7 HTTP metrics/policy behavior for that port.

## Cleanup

For the Makefile-managed k3d environment:

```bash
make clean
```

For a manual Helm install:

```bash
helm uninstall linkerd-header-repro --namespace linkerd-header-repro
kubectl delete namespace linkerd-header-repro
```

## Suggested upstream fix

Expose HTTP/2 client-side max header list size in Linkerd proxy, e.g.

```text
LINKERD2_PROXY_OUTBOUND_CONNECT_HTTP2_MAX_HEADER_LIST_SIZE=131072
LINKERD2_PROXY_INBOUND_CONNECT_HTTP2_MAX_HEADER_LIST_SIZE=131072
```

Internally this likely means adding `max_header_list_size` to Linkerd's HTTP/2 `ClientParams` and calling Hyper's HTTP/2 client builder `max_header_list_size(...)`.
