#!/usr/bin/env bash
set -euo pipefail

cluster="${K3D_CLUSTER:-linkerd-header-repro}"
context="k3d-${cluster}"
linkerd_bin="${LINKERD_BIN:-./.bin/linkerd2/bin/linkerd}"
timeout_seconds="${TEST_TIMEOUT_SECONDS:-90}"
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
chart_dir="${root_dir}/chart"
grpc_dir="${root_dir}/grpc-repro"
grpc_image="${GRPC_REPRO_IMAGE:-linkerd-grpc-header-repro:local}"

http_results=()
grpc_results=()
failures=0

die() {
  echo "error: $*" >&2
  exit 1
}

use_cluster() {
  kubectl config use-context "${context}" >/dev/null
  kubectl get namespace linkerd >/dev/null 2>&1 \
    || die "Linkerd is not installed; run make setup first"
}

linkerd_version() {
  if [[ -x "${linkerd_bin}" ]]; then
    "${linkerd_bin}" version 2>/dev/null | tr '\n' '; ' | sed 's/; $//'
    return
  fi

  kubectl -n linkerd get deploy linkerd-destination \
    -o jsonpath='Server proxy image: {.spec.template.spec.initContainers[*].image}{"\n"}'
}

install_http_variation() {
  local namespace="$1"
  local release="$2"
  local header_bytes="$3"
  local opaque="$4"

  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local args=(
    upgrade --install "${release}" "${chart_dir}"
    --namespace "${namespace}"
    --set "server.largeHeaderBytes=${header_bytes}"
    --wait
  )

  if [[ "${opaque}" == "yes" ]]; then
    args+=(--set-string 'server.podAnnotations.config\.linkerd\.io/opaque-ports=8080')
  fi

  helm "${args[@]}" >/dev/null
}

wait_for_http_rollout() {
  local namespace="$1"
  local release="$2"

  kubectl -n "${namespace}" rollout status "deploy/${release}-server" --timeout=120s >/dev/null
  kubectl -n "${namespace}" rollout status "deploy/${release}-meshed-client" --timeout=120s >/dev/null
  kubectl -n "${namespace}" rollout status "deploy/${release}-unmeshed-client" --timeout=120s >/dev/null
}

curl_from_client() {
  local namespace="$1"
  local deploy="$2"
  local url="$3"

  kubectl -n "${namespace}" exec "deploy/${deploy}" -c curl -- sh -ceu '
    url="$1"
    rm -f /tmp/repro-body /tmp/repro-headers
    curl -sS --max-time 8 "${url}" \
      -o /tmp/repro-body \
      -D /tmp/repro-headers \
      -w "curl_http_code=%{http_code}\n" || true
    awk '\''
      /^HTTP\// { gsub(/\r/, ""); print "status_line=" $0 }
      tolower($0) ~ /^l5d-proxy-error:/ { gsub(/\r/, ""); print }
      tolower($0) ~ /^x-large-response-header:/ {
        gsub(/\r/, "")
        value=$0
        sub(/^[^:]*: ?/, "", value)
        print "x_large_header_value_bytes=" length(value)
      }
    '\'' /tmp/repro-headers
    cat /tmp/repro-body 2>/dev/null || true
  ' sh "${url}" 2>&1
}

extract_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key { value=$2 } END { print value }'
}

probe_http_until_ready() {
  local namespace="$1"
  local deploy="$2"
  local url="$3"
  local expect_code="$4"
  local output_var="$5"
  local deadline=$((SECONDS + timeout_seconds))
  local output=""
  local code=""

  while (( SECONDS < deadline )); do
    output="$(curl_from_client "${namespace}" "${deploy}" "${url}" || true)"
    code="$(printf '%s\n' "${output}" | extract_value curl_http_code)"
    if [[ "${code}" == "${expect_code}" ]]; then
      printf -v "${output_var}" '%s' "${output}"
      return 0
    fi
    sleep 3
  done

  printf -v "${output_var}" '%s' "${output}"
  return 1
}

status_icon() {
  if [[ "$1" == "PASS" ]]; then
    printf '✓'
  else
    printf '✗'
  fi
}

run_http_variation() {
  local name="$1"
  local namespace="$2"
  local release="$3"
  local header_bytes="$4"
  local opaque="$5"
  local expect_meshed_large="$6"

  echo "==> HTTP ${name}: header=${header_bytes}, opaque=${opaque}"
  install_http_variation "${namespace}" "${release}" "${header_bytes}" "${opaque}"
  wait_for_http_rollout "${namespace}" "${release}"

  local base="http://${release}-server:8080"
  local meshed_small=""
  local meshed_large=""
  local unmeshed_large=""
  local result="PASS"

  probe_http_until_ready "${namespace}" "${release}-meshed-client" "${base}/small" 200 meshed_small \
    || result="FAIL"
  probe_http_until_ready \
    "${namespace}" "${release}-meshed-client" "${base}/large" \
    "${expect_meshed_large}" meshed_large || result="FAIL"
  probe_http_until_ready "${namespace}" "${release}-unmeshed-client" "${base}/large" 200 unmeshed_large \
    || result="FAIL"

  local small_code large_code unmeshed_code large_bytes proxy_error
  small_code="$(printf '%s\n' "${meshed_small}" | extract_value curl_http_code)"
  large_code="$(printf '%s\n' "${meshed_large}" | extract_value curl_http_code)"
  unmeshed_code="$(printf '%s\n' "${unmeshed_large}" | extract_value curl_http_code)"
  large_bytes="$(printf '%s\n' "${unmeshed_large}" | extract_value configured_header_value_bytes)"
  proxy_error="$(printf '%s\n' "${meshed_large}" | grep -ci '^l5d-proxy-error:' || true)"

  if [[ "${result}" != "PASS" ]]; then
    failures=$((failures + 1))
  fi

  http_results+=("${name}|${header_bytes}|${opaque}|${small_code:-?}|${large_code:-?}|${unmeshed_code:-?}|${large_bytes:-?}|${proxy_error}|${result}")
  echo "    $(status_icon "${result}") ${result}"
}

build_grpc_image() {
  echo "==> Building gRPC repro image ${grpc_image}"
  docker build -t "${grpc_image}" "${grpc_dir}" >/dev/null
  k3d image import "${grpc_image}" -c "${cluster}" >/dev/null
}

apply_grpc_variation() {
  local namespace="$1"
  local release="$2"
  local trailer_bytes="$3"
  local opaque="$4"

  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  render_grpc_service "${namespace}" "${release}" | kubectl apply -f - >/dev/null
  render_grpc_server "${namespace}" "${release}" "${trailer_bytes}" "${opaque}" \
    | kubectl apply -f - >/dev/null
  render_grpc_client "${namespace}" "${release}" meshed enabled \
    | kubectl apply -f - >/dev/null
  render_grpc_client "${namespace}" "${release}" unmeshed disabled \
    | kubectl apply -f - >/dev/null
}

render_grpc_service() {
  local namespace="$1"
  local release="$2"

  cat <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${release}-server
  namespace: ${namespace}
spec:
  selector:
    app.kubernetes.io/instance: ${release}
    app.kubernetes.io/component: grpc-server
  ports:
    - name: grpc
      port: 9090
      targetPort: grpc
YAML
}

render_grpc_server() {
  local namespace="$1"
  local release="$2"
  local trailer_bytes="$3"
  local opaque="$4"
  local opaque_annotation=""

  if [[ "${opaque}" == "yes" ]]; then
    opaque_annotation='        config.linkerd.io/opaque-ports: "9090"'
  fi

  cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${release}-server
  namespace: ${namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: ${release}
      app.kubernetes.io/component: grpc-server
  template:
    metadata:
      annotations:
        linkerd.io/inject: enabled
${opaque_annotation}
      labels:
        app.kubernetes.io/instance: ${release}
        app.kubernetes.io/component: grpc-server
    spec:
      containers:
        - name: grpc-repro
          image: ${grpc_image}
          imagePullPolicy: IfNotPresent
          args: ["server"]
          env:
            - name: PAD_TRAILER_BYTES
              value: "${trailer_bytes}"
          ports:
            - name: grpc
              containerPort: 9090
YAML
}

render_grpc_client() {
  local namespace="$1"
  local release="$2"
  local client_kind="$3"
  local inject="$4"

  cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${release}-${client_kind}-client
  namespace: ${namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: ${release}
      app.kubernetes.io/component: grpc-${client_kind}-client
  template:
    metadata:
      annotations:
        linkerd.io/inject: ${inject}
      labels:
        app.kubernetes.io/instance: ${release}
        app.kubernetes.io/component: grpc-${client_kind}-client
    spec:
      containers:
        - name: grpc-repro
          image: ${grpc_image}
          imagePullPolicy: IfNotPresent
          command: ["sleep", "infinity"]
YAML
}

wait_for_grpc_rollout() {
  local namespace="$1"
  local release="$2"

  kubectl -n "${namespace}" rollout status "deploy/${release}-server" --timeout=120s >/dev/null
  kubectl -n "${namespace}" rollout status "deploy/${release}-meshed-client" --timeout=120s >/dev/null
  kubectl -n "${namespace}" rollout status "deploy/${release}-unmeshed-client" --timeout=120s >/dev/null
}

grpc_from_client() {
  local namespace="$1"
  local deploy="$2"
  local target="$3"

  kubectl -n "${namespace}" exec "deploy/${deploy}" -c grpc-repro -- \
    env TARGET="${target}" /usr/local/bin/grpc-repro client 2>&1 || true
}

probe_grpc_until_ready() {
  local namespace="$1"
  local deploy="$2"
  local target="$3"
  local expect_code="$4"
  local expect_pad_bytes="$5"
  local output_var="$6"
  local deadline=$((SECONDS + timeout_seconds))
  local output=""
  local code=""
  local pad_bytes=""

  while (( SECONDS < deadline )); do
    output="$(grpc_from_client "${namespace}" "${deploy}" "${target}" || true)"
    code="$(printf '%s\n' "${output}" | extract_value grpc_code)"
    pad_bytes="$(printf '%s\n' "${output}" | extract_value x_echo_pad_value_bytes)"
    if [[ "${code}" == "${expect_code}" && "${pad_bytes}" == "${expect_pad_bytes}" ]]; then
      printf -v "${output_var}" '%s' "${output}"
      return 0
    fi
    sleep 3
  done

  printf -v "${output_var}" '%s' "${output}"
  return 1
}

run_grpc_variation() {
  local name="$1"
  local namespace="$2"
  local release="$3"
  local trailer_bytes="$4"
  local opaque="$5"
  local expect_meshed_code="$6"
  local expect_meshed_pad="$7"
  local expect_unmeshed_code="$8"
  local expect_unmeshed_pad="$9"

  echo "==> gRPC ${name}: trailer=${trailer_bytes}, opaque=${opaque}"
  apply_grpc_variation "${namespace}" "${release}" "${trailer_bytes}" "${opaque}"
  wait_for_grpc_rollout "${namespace}" "${release}"

  local target="${release}-server:9090"
  local meshed=""
  local unmeshed=""
  local result="PASS"

  probe_grpc_until_ready \
    "${namespace}" "${release}-meshed-client" "${target}" \
    "${expect_meshed_code}" "${expect_meshed_pad}" meshed || result="FAIL"
  probe_grpc_until_ready \
    "${namespace}" "${release}-unmeshed-client" "${target}" \
    "${expect_unmeshed_code}" "${expect_unmeshed_pad}" unmeshed || result="FAIL"

  local meshed_code meshed_pad unmeshed_code unmeshed_pad trailer_count
  meshed_code="$(printf '%s\n' "${meshed}" | extract_value grpc_code)"
  meshed_pad="$(printf '%s\n' "${meshed}" | extract_value x_echo_pad_value_bytes)"
  unmeshed_code="$(printf '%s\n' "${unmeshed}" | extract_value grpc_code)"
  unmeshed_pad="$(printf '%s\n' "${unmeshed}" | extract_value x_echo_pad_value_bytes)"
  trailer_count="$(printf '%s\n' "${meshed}" | extract_value x_echo_message_count)"

  if [[ "${result}" != "PASS" ]]; then
    failures=$((failures + 1))
  fi

  grpc_results+=("${name}|${trailer_bytes}|${opaque}|${meshed_code:-?}|${meshed_pad:-?}|${unmeshed_code:-?}|${unmeshed_pad:-?}|${trailer_count:-?}|${result}")
  echo "    $(status_icon "${result}") ${result}"
}

print_http_report() {
  printf '| Variation | Header bytes | Opaque | Meshed /small | Meshed /large | Unmeshed /large | Body bytes | Proxy error | Result |\n'
  printf '|---|---:|:---:|---:|---:|---:|---:|:---:|:---:|\n'

  local row
  for row in "${http_results[@]}"; do
    IFS='|' read -r name header opaque small large unmeshed bytes proxy_error result <<<"${row}"
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "${name}" "${header}" "${opaque}" "${small}" "${large}" \
      "${unmeshed}" "${bytes}" "${proxy_error}" "${result}"
  done
}

print_grpc_report() {
  printf '| Variation | Trailer bytes | Opaque | Meshed code | Meshed trailer bytes | Unmeshed code | Unmeshed trailer bytes | Meshed trailer count | Result |\n'
  printf '|---|---:|:---:|---|---:|---|---:|---:|:---:|\n'

  local row
  for row in "${grpc_results[@]}"; do
    IFS='|' read -r name bytes opaque meshed_code meshed_pad unmeshed_code unmeshed_pad count result <<<"${row}"
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "${name}" "${bytes}" "${opaque}" "${meshed_code}" "${meshed_pad}" \
      "${unmeshed_code}" "${unmeshed_pad}" "${count}" "${result}"
  done
}

print_report() {
  echo
  echo "# Linkerd max response metadata repro report"
  echo
  echo "Cluster: ${context}"
  echo "Linkerd: $(linkerd_version)"
  echo
  echo "## HTTP response headers"
  echo
  print_http_report
  echo
  echo "Expected HTTP signal: 22k normal fails only in meshed /large; 12k and opaque 22k pass."
  echo
  echo "## gRPC response trailers"
  echo
  print_grpc_report
  echo
  echo "Expected gRPC signal: 22k trailers return Internal with missing trailers when either Linkerd side parses HTTP/2; opaque 22k proves the unmeshed client receives the original Unauthenticated status and trailers."
}

main() {
  use_cluster

  run_http_variation "12k baseline" \
    linkerd-header-repro-12k linkerd-header-repro-12k 12000 no 200
  run_http_variation "22k repro" \
    linkerd-header-repro-22k linkerd-header-repro-22k 22000 no 502
  run_http_variation "22k opaque" \
    linkerd-header-repro-opaque linkerd-header-repro-opaque 22000 yes 200

  build_grpc_image
  run_grpc_variation "8k baseline" \
    linkerd-grpc-repro-8k linkerd-grpc-repro-8k \
    8000 no Unauthenticated 8000 Unauthenticated 8000
  run_grpc_variation "22k repro" \
    linkerd-grpc-repro-22k linkerd-grpc-repro-22k \
    22000 no Internal 0 Internal 0
  run_grpc_variation "22k opaque" \
    linkerd-grpc-repro-opaque linkerd-grpc-repro-opaque \
    22000 yes Internal 0 Unauthenticated 22000

  print_report
  (( failures == 0 ))
}

main "$@"
