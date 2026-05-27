K3D_CLUSTER ?= linkerd-header-repro
LINKERD_VERSION ?= edge-26.5.3
LINKERD_INSTALL_ROOT ?= $(CURDIR)/.bin/linkerd2
LINKERD_BIN ?= $(LINKERD_INSTALL_ROOT)/bin/linkerd
GRPC_REPRO_IMAGE ?= linkerd-grpc-header-repro:local
TEST_TIMEOUT_SECONDS ?= 90

PROXY_IMAGE ?= localhost/linkerd/proxy:fix-15199-local
PROXY_HTTP2_MAX_HEADER_LIST_SIZE ?= 131072

.PHONY: setup test deploy-proxy clean clean-repro clean-cluster

setup:
	K3D_CLUSTER=$(K3D_CLUSTER) \
	LINKERD_VERSION=$(LINKERD_VERSION) \
	LINKERD_INSTALL_ROOT=$(LINKERD_INSTALL_ROOT) \
	./scripts/setup-k3d.sh

test:
	K3D_CLUSTER=$(K3D_CLUSTER) \
	LINKERD_BIN=$(LINKERD_BIN) \
	GRPC_REPRO_IMAGE=$(GRPC_REPRO_IMAGE) \
	TEST_TIMEOUT_SECONDS=$(TEST_TIMEOUT_SECONDS) \
	PROXY_VERSION=$(PROXY_VERSION) \
	./scripts/test-variations.sh

deploy-proxy:
	K3D_CLUSTER=$(K3D_CLUSTER) \
	LINKERD_BIN=$(LINKERD_BIN) \
	PROXY_IMAGE=$(PROXY_IMAGE) \
	PROXY_VERSION=$(PROXY_VERSION) \
	PROXY_HTTP2_MAX_HEADER_LIST_SIZE=$(PROXY_HTTP2_MAX_HEADER_LIST_SIZE) \
	./scripts/deploy-custom-proxy.sh

clean-repro:
	kubectl config use-context k3d-$(K3D_CLUSTER)
	kubectl delete namespace \
		linkerd-header-repro-12k \
		linkerd-header-repro-22k \
		linkerd-header-repro-opaque \
		linkerd-grpc-repro-8k \
		linkerd-grpc-repro-22k \
		linkerd-grpc-repro-opaque \
		--ignore-not-found

clean:
	-k3d cluster delete $(K3D_CLUSTER)
	-docker rmi -f $(GRPC_REPRO_IMAGE)
	rm -rf $(LINKERD_INSTALL_ROOT)

clean-cluster:
	k3d cluster delete $(K3D_CLUSTER)
