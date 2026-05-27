#!/usr/bin/env bash
set -euo pipefail

namespace="${1:-linkerd-header-repro}"
release="${2:-linkerd-header-repro}"

printf '## Pods\n'
kubectl -n "${namespace}" get pods -o wide

printf '\n## Images\n'
kubectl -n "${namespace}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name} {.image}{"\n"}{end}{"\n"}{end}'

printf '\n## Meshed client recent logs\n'
kubectl -n "${namespace}" logs "deploy/${release}-meshed-client" -c curl --tail=80 || true

printf '\n## Unmeshed client recent logs\n'
kubectl -n "${namespace}" logs "deploy/${release}-unmeshed-client" -c curl --tail=80 || true

printf '\n## Linkerd sidecar recent logs from meshed client\n'
kubectl -n "${namespace}" logs "deploy/${release}-meshed-client" -c linkerd-proxy --tail=120 || true
