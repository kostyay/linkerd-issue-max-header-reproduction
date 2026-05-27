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

```bash
make setup
make test
```

`make test` runs:

- HTTP response header checks: 12 KiB baseline, 22 KiB repro, 22 KiB opaque-port workaround.
- gRPC response trailer checks: 8 KiB baseline, 22 KiB repro, 22 KiB opaque server-port control.

Clean up everything created by the Makefile:

```bash
make clean
```

Useful overrides:

```bash
make setup K3D_CLUSTER=my-repro LINKERD_VERSION=edge-26.5.3
make test K3D_CLUSTER=my-repro TEST_TIMEOUT_SECONDS=120
```

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
  -o jsonpath='{.items[0].spec.containers[*].image}{"\n"}'
```

Look for the `cr.l5d.io/linkerd/proxy:<version>` sidecar image.

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
