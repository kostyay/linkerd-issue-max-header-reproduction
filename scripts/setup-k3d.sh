#!/usr/bin/env bash
set -euo pipefail

cluster="${K3D_CLUSTER:-linkerd-header-repro}"
linkerd_version="${LINKERD_VERSION:-edge-26.5.3}"
install_root="${LINKERD_INSTALL_ROOT:-./.bin/linkerd2}"
case "${install_root}" in
  /*) ;;
  *) install_root="${PWD}/${install_root#./}" ;;
esac
linkerd_bin="${install_root}/bin/linkerd"
context="k3d-${cluster}"

die() {
  echo "error: $*" >&2
  exit 1
}

ensure_tool() {
  local tool="$1"
  if command -v "${tool}" >/dev/null 2>&1; then
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    echo "Installing ${tool} with Homebrew..."
    brew install "${tool}"
    return
  fi

  die "missing ${tool}; install it or install Homebrew"
}

ensure_linkerd_cli() {
  if [[ -x "${linkerd_bin}" ]]; then
    "${linkerd_bin}" version --client
    return
  fi

  if [[ -L "${linkerd_bin}" && ! -e "${linkerd_bin}" ]]; then
    rm -f "${linkerd_bin}"
  fi

  mkdir -p "${install_root}"
  echo "Installing Linkerd ${linkerd_version} into ${install_root}..."
  curl -fsSL https://run.linkerd.io/install-edge \
    | env LINKERD2_VERSION="${linkerd_version}" INSTALLROOT="${install_root}" sh
  "${linkerd_bin}" version --client
}

ensure_cluster() {
  if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${cluster}"; then
    echo "Using existing k3d cluster ${cluster}"
  else
    echo "Creating k3d cluster ${cluster}..."
    k3d cluster create "${cluster}" \
      --agents 1 \
      --k3s-arg '--disable=traefik@server:0' \
      --wait
  fi

  kubectl config use-context "${context}"
  kubectl get nodes
}

install_linkerd() {
  kubectl apply \
    -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

  if kubectl get namespace linkerd >/dev/null 2>&1; then
    "${linkerd_bin}" upgrade --crds | kubectl apply -f -
    "${linkerd_bin}" upgrade | kubectl apply -f -
  else
    "${linkerd_bin}" check --pre
    "${linkerd_bin}" install --crds | kubectl apply -f -
    "${linkerd_bin}" install | kubectl apply -f -
  fi

  kubectl -n linkerd rollout status deploy/linkerd-destination --timeout=240s
  kubectl -n linkerd rollout status deploy/linkerd-identity --timeout=240s
  kubectl -n linkerd rollout status deploy/linkerd-proxy-injector --timeout=240s
  "${linkerd_bin}" check
}

main() {
  ensure_tool docker
  ensure_tool k3d
  ensure_tool kubectl
  ensure_tool helm
  docker info >/dev/null 2>&1 || die "Docker is not running"

  ensure_linkerd_cli
  ensure_cluster
  install_linkerd

  echo
  echo "Setup complete. Run: make test"
}

main "$@"
