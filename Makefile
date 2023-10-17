###########################
# Configuration Variables #
###########################
ORG := github.com/operator-framework
PKG := $(ORG)/rukpak
GO_INSTALL_OPTS ?= "-mod=readonly"
export IMAGE_REPO ?= quay.io/operator-framework/rukpak
export IMAGE_TAG ?= latest
IMAGE?=$(IMAGE_REPO):$(IMAGE_TAG)
KIND_CLUSTER_NAME ?= rukpak
BIN_DIR := bin
TESTDATA_DIR := testdata
VERSION_PATH := $(PKG)/internal/version
GIT_COMMIT ?= $(shell git rev-parse HEAD)
PKGS = $(shell go list ./...)
export CERT_MGR_VERSION ?= v1.7.1
RUKPAK_NAMESPACE ?= rukpak-system

REGISTRY_NAME="docker-registry"
REGISTRY_NAMESPACE=rukpak-e2e
DNS_NAME=$(REGISTRY_NAME).$(REGISTRY_NAMESPACE).svc.cluster.local

CONTAINER_RUNTIME ?= docker
KUBECTL ?= kubectl

# kernel-style V=1 build verbosity
ifeq ("$(origin V)", "command line")
  BUILD_VERBOSE = $(V)
endif

ifeq ($(BUILD_VERBOSE),1)
  Q =
else
  Q = @
endif

###############
# Help Target #
###############
.PHONY: help
help: ## Show this help screen
	@echo 'Usage: make <OPTIONS> ... <TARGETS>'
	@echo ''
	@echo 'Available targets are:'
	@echo ''
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

###################
# Code management #
###################
.PHONY: lint tidy fmt clean generate verify

##@ code management:

lint: golangci-lint ## Run golangci linter
	# Set the golangci-lint cache directory to a directory that's
	# writable in downstream CI.
	GOLANGCI_LINT_CACHE=/tmp/golangci-cache $(GOLANGCI_LINT) run

tidy: ## Update dependencies
	$(Q)go mod tidy

clean: ## Remove binaries and test artifacts
	@rm -rf bin

generate: controller-gen ## Generate code and manifests
	$(Q)$(CONTROLLER_GEN) crd:crdVersions=v1,generateEmbeddedObjectMeta=true output:crd:dir=./manifests/apis/crds paths=./api/...
	$(Q)$(CONTROLLER_GEN) webhook paths=./api/... output:stdout > ./manifests/apis/webhooks/resources/webhook.yaml
	$(Q)$(CONTROLLER_GEN) object:headerFile=./hack/boilerplate.go.txt paths=./api/...
	$(Q)$(CONTROLLER_GEN) rbac:roleName=core-admin \
		paths=./internal/provisioner/plain/... \
		paths=./internal/provisioner/registry/... \
		paths=./internal/uploadmgr/... \
			output:stdout > ./manifests/core/resources/cluster_role.yaml

verify: tidy generate ## Verify the current code generation and lint
	git diff --exit-code

###########
# Testing #
###########
.PHONY: test test-unit test-e2e image-registry

##@ testing:

test: test-unit test-e2e ## Run the tests

.PHONY: setup-envtest
setup-envtest: envtest
	$(eval KUBEBUILDER_ASSETS := "$(shell $(ENVTEST) use $(ENVTEST_VERSION) -p path --bin-dir $(LOCALBIN))")

ENVTEST_VERSION = $(shell go list -m k8s.io/client-go | cut -d" " -f2 | sed 's/^v0\.\([[:digit:]]\{1,\}\)\.[[:digit:]]\{1,\}$$/1.\1.x/')
UNIT_TEST_DIRS=$(shell go list ./... | grep -v /test/)
test-unit: setup-envtest ## Run the unit tests
	KUBEBUILDER_ASSETS=$(KUBEBUILDER_ASSETS) go test -count=1 -short $(UNIT_TEST_DIRS)

FOCUS := $(if $(TEST),-v -focus "$(TEST)")
test-e2e: ginkgo ## Run the e2e tests
	$(GINKGO) -trace -progress $(FOCUS) test/e2e

e2e: KIND_CLUSTER_NAME=rukpak-e2e
e2e: run image-registry kind-load-bundles registry-load-bundles test-e2e kind-cluster-cleanup ## Run e2e tests against an ephemeral kind cluster

kind-cluster: kind kind-cluster-cleanup ## Standup a kind cluster
	$(KIND) create cluster --name ${KIND_CLUSTER_NAME}
	$(KIND) export kubeconfig --name ${KIND_CLUSTER_NAME}

kind-cluster-cleanup: kind ## Delete the kind cluster
	$(KIND) delete cluster --name ${KIND_CLUSTER_NAME}

image-registry: ## Setup in-cluster image registry
	./tools/imageregistry/setup_imageregistry.sh ${KIND_CLUSTER_NAME}

###################
# Install and Run #
###################
.PHONY: install install-manifests wait run cert-mgr uninstall

##@ install/run:

install: generate cert-mgr install-manifests wait ## Install rukpak

install-manifests:
	kubectl apply -k manifests

wait:
	kubectl wait --for=condition=Available --namespace=$(RUKPAK_NAMESPACE) deployment/core --timeout=60s
	kubectl wait --for=condition=Available --namespace=$(RUKPAK_NAMESPACE) deployment/rukpak-webhooks --timeout=60s

run: build-container kind-cluster kind-load install ## Build image, stop/start a local kind cluster, and run operator in that cluster

##################
# Build and Load #
##################
.PHONY: build plain unpack core rukpakctl build-container kind-load kind-load-bundles kind-cluster registry-load-bundles

##@ build/load:

BINARIES=core helm unpack webhooks crdvalidator rukpakctl
LINUX_BINARIES=$(join $(addprefix linux/,$(BINARIES)), )

.PHONY: build $(BINARIES) $(LINUX_BINARIES) build-container kind-load kind-load-bundles kind-cluster registry-load-bundles

VERSION_FLAGS=-ldflags "-X $(VERSION_PATH).GitCommit=$(GIT_COMMIT)"

# Binary builds
build: $(BINARIES)

$(LINUX_BINARIES):
	CGO_ENABLED=0 GOOS=linux go build $(VERSION_FLAGS) -o $(BIN_DIR)/$@ ./cmd/$(notdir $@)

$(BINARIES):
	CGO_ENABLED=0 go build $(VERSION_FLAGS) -o $(BIN_DIR)/$@ ./cmd/$@

build-container: $(LINUX_BINARIES) ## Builds provisioner container image locally
	$(CONTAINER_RUNTIME) build -f Dockerfile -t $(IMAGE) $(BIN_DIR)/linux

kind-load-bundles: kind ## Load the e2e testdata container images into a kind cluster
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/plain-v0/valid -t testdata/bundles/plain-v0:valid
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/plain-v0/dependent -t testdata/bundles/plain-v0:dependent
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/plain-v0/provides -t testdata/bundles/plain-v0:provides
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/plain-v0/empty -t testdata/bundles/plain-v0:empty
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/plain-v0/no-manifests -t testdata/bundles/plain-v0:no-manifests
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/plain-v0/invalid-missing-crds -t testdata/bundles/plain-v0:invalid-missing-crds
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/plain-v0/invalid-crds-and-crs -t testdata/bundles/plain-v0:invalid-crds-and-crs
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/plain-v0/subdir -t testdata/bundles/plain-v0:subdir
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/registry/valid -t testdata/bundles/registry:valid
	$(CONTAINER_RUNTIME) build $(TESTDATA_DIR)/bundles/registry/invalid -t testdata/bundles/registry:invalid
	$(KIND) load docker-image testdata/bundles/plain-v0:valid --name $(KIND_CLUSTER_NAME)
	$(KIND) load docker-image testdata/bundles/plain-v0:dependent --name $(KIND_CLUSTER_NAME)
	$(KIND) load docker-image testdata/bundles/plain-v0:provides --name $(KIND_CLUSTER_NAME)
	$(KIND) load docker-image testdata/bundles/plain-v0:empty --name $(KIND_CLUSTER_NAME)
	$(KIND) load docker-image testdata/bundles/plain-v0:no-manifests --name $(KIND_CLUSTER_NAME)
	$(KIND) load docker-image testdata/bundles/plain-v0:invalid-missing-crds --name $(KIND_CLUSTER_NAME)
	$(KIND) load docker-image testdata/bundles/plain-v0:invalid-crds-and-crs --name $(KIND_CLUSTER_NAME)
	$(KIND) load docker-image testdata/bundles/plain-v0:subdir --name $(KIND_CLUSTER_NAME)
	$(KIND) load docker-image testdata/bundles/registry:valid --name $(KIND_CLUSTER_NAME)
	$(KIND) load docker-image testdata/bundles/registry:invalid --name $(KIND_CLUSTER_NAME)

kind-load: kind ## Loads the currently constructed image onto the cluster
	$(KIND) load docker-image $(IMAGE) --name $(KIND_CLUSTER_NAME)

registry-load-bundles: ## Load selected e2e testdata container images created in kind-load-bundles into registry
	$(CONTAINER_RUNTIME) tag testdata/bundles/plain-v0:valid $(DNS_NAME):5000/bundles/plain-v0:valid
	./tools/imageregistry/load_test_image.sh $(KIND) $(KIND_CLUSTER_NAME)

###########
# Release #
###########

##@ release:

export DISABLE_RELEASE_PIPELINE ?= true
substitute:
	envsubst < .goreleaser.template.yml > .goreleaser.yml

release: GORELEASER_ARGS ?= --snapshot --rm-dist
release: goreleaser substitute ## Run goreleaser
	$(GORELEASER) $(GORELEASER_ARGS)

quickstart: VERSION ?= $(shell git describe --abbrev=0 --tags)
quickstart: generate ## Generate the installation release manifests
	$(KUBECTL) kustomize manifests | sed "s/:latest/:$(VERSION)/g" > rukpak.yaml

################
# Hack / Tools #
################

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest
GINKGO ?= $(LOCALBIN)/ginkgo
GOLANGCI_LINT ?= $(LOCALBIN)/golangci-lint
KIND ?= $(LOCALBIN)/kind

## Tool Versions
KUSTOMIZE_VERSION ?= v3.8.7
CONTROLLER_TOOLS_VERSION ?= v0.9.0
SETUP_ENVTEST_VERSION ?= cd0058a # v0.12.3
GINKGO_VERSION ?= v2.1.4
GOLANGCI_LINT_VERSION ?= v1.46.0
KIND_VERSION ?= v0.14.0

KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE): $(LOCALBIN)
	rm -f $(KUSTOMIZE)
	curl -s $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN)

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install $(GO_INSTALL_OPTS) sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install $(GO_INSTALL_OPTS) sigs.k8s.io/controller-runtime/tools/setup-envtest@$(SETUP_ENVTEST_VERSION)

.PHONY: ginkgo
ginkgo: $(GINKGO)
$(GINKGO): $(LOCALBIN) ## Download ginkgo locally if necessary.
	GOBIN=$(LOCALBIN) go install $(GO_INSTALL_OPTS) github.com/onsi/ginkgo/v2/ginkgo@$(GINKGO_VERSION)

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT)
$(GOLANGCI_LINT): $(LOCALBIN) ## Download golangci-lint locally if necessary.
	GOBIN=$(LOCALBIN) go install $(GO_INSTALL_OPTS) github.com/golangci/golangci-lint/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)

.PHONY: kind
kind: $(KIND) ## Download kind locally if necessary.
$(KIND): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install $(GO_INSTALL_OPTS) sigs.k8s.io/kind@$(KIND_VERSION)
