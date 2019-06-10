PACKAGE:=github.com/argoproj/argo-cd
DIST_DIR:=$(CURDIR)/dist
CLI_NAME:=argocd

VERSION:=$(shell cat -- '$(CURDIR)/VERSION')
BUILD_DATE:=$(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
GIT_COMMIT:=$(shell git rev-parse HEAD)
GIT_TAG:=$(shell if [ -z "`git status --porcelain`" ]; then git describe --exact-match --tags HEAD 2>/dev/null; fi)
GIT_TREE_STATE:=$(shell if [ -z "`git status --porcelain`" ]; then echo "clean" ; else echo "dirty"; fi)

PATH:=$(PATH):$(CURDIR)/hack

# Use GOPATH from within docker, the project folder otherwise
VENDOR_DIR:=$(shell if [ -f /.dockerenv ]; then echo "$$GOPATH/src"; else echo '$(CURDIR)/vendor'; fi)

# docker image publishing options
DOCKER_PUSH?=false
IMAGE_TAG?=latest
# perform static compilation
STATIC_BUILD?=true
# build development images
DEV_IMAGE?=false

HOST_OS?=$(shell eval $$(go env) && echo $$GOHOSTOS)
HOST_ARCH?=$(shell eval $$(go env) && echo $$GOHOSTARCH)

PROTO_FILES:=$(shell find server reposerver -type f -name "*.proto")
SERVER_PROTO_FILES:=$(shell find server -type f -name "*.proto")

override LDFLAGS += \
  -X ${PACKAGE}/common.version=${VERSION} \
  -X ${PACKAGE}/common.buildDate=${BUILD_DATE} \
  -X ${PACKAGE}/common.gitCommit=${GIT_COMMIT} \
  -X ${PACKAGE}/common.gitTreeState=${GIT_TREE_STATE}

ifeq (${STATIC_BUILD}, true)
override LDFLAGS += -extldflags "-static"
endif

ifneq (${GIT_TAG},)
IMAGE_TAG=${GIT_TAG}
LDFLAGS += -X ${PACKAGE}/common.gitTag=${GIT_TAG}
endif

ifeq (${DOCKER_PUSH},true)
ifndef IMAGE_NAMESPACE
$(error IMAGE_NAMESPACE must be set to push images (e.g. IMAGE_NAMESPACE=argoproj))
endif
endif

ifdef IMAGE_NAMESPACE
IMAGE_PREFIX=${IMAGE_NAMESPACE}/
endif

.PHONY: all
all: cli image argocd-util

.PHONY: protogen
protogen: \
	$(addsuffix .pb.go,$(basename $(PROTO_FILES))) \
	$(addsuffix .pb.gw.go,$(basename $(SERVER_PROTO_FILES))) \
	assets/swagger.json

.PHONY: openapigen
openapigen:
	go run ./vendor/k8s.io/kube-openapi/cmd/openapi-gen/openapi-gen.go \
		--go-header-file hack/custom-boilerplate.go.txt \
		--input-dirs $(PACKAGE)/pkg/apis/application/v1alpha1 \
		--output-package $(PACKAGE)/pkg/apis/application/v1alpha1 \
		--report-filename pkg/apis/api-rules/violation_exceptions.list

	go run ./hack/update-openapi-validation/main.go \
		manifests/crds/application-crd.yaml \
		$(PACKAGE)/pkg/apis/application/v1alpha1.Application

	go run ./hack/update-openapi-validation/main.go \
		manifests/crds/appproject-crd.yaml \
		$(PACKAGE)/pkg/apis/application/v1alpha1.AppProject

.PHONY: clientgen
clientgen:
	bash -x vendor/k8s.io/code-generator/generate-groups.sh \
		deepcopy,client,informer,lister \
		$(PACKAGE)/pkg/client \
		$(PACKAGE)/pkg/apis \
		application:v1alpha1 \
		--go-header-file hack/custom-boilerplate.go.txt \

.PHONY: codegen
codegen: protogen clientgen openapigen manifests

.PHONY: cli
cli: clean-debug | dist/packr
	CGO_ENABLED=0 dist/packr build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/${CLI_NAME} ./cmd/argocd

.PHONY: release-cli
release-cli: clean-debug image
	docker create --name tmp-argocd-linux $(IMAGE_PREFIX)argocd:$(IMAGE_TAG)
	docker cp tmp-argocd-linux:/usr/local/bin/argocd ${DIST_DIR}/argocd-linux-amd64
	docker cp tmp-argocd-linux:/usr/local/bin/argocd-darwin-amd64 ${DIST_DIR}/argocd-darwin-amd64
	docker rm tmp-argocd-linux

.PHONY: argocd-util
argocd-util: clean-debug
	# Build argocd-util as a statically linked binary, so it could run within the
	# alpine-based dex container (argoproj/argo-cd#844)
	CGO_ENABLED=0 go build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-util ./cmd/argocd-util

.PHONY: manifests
manifests:
	./hack/update-manifests.sh

# NOTE: we use packr to do the build instead of go, since we embed swagger files
# and policy.csv files into the go binary
.PHONY: server
server: clean-debug | dist/packr
	CGO_ENABLED=0 dist/packr build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-server ./cmd/argocd-server

.PHONY: repo-server
repo-server:
	CGO_ENABLED=0 go build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-repo-server ./cmd/argocd-repo-server

.PHONY: controller
controller:
	CGO_ENABLED=0 ${PACKR_CMD} build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-application-controller ./cmd/argocd-application-controller

.PHONY: image
ifeq ($(DEV_IMAGE), true)
# The "dev" image builds the binaries from the users desktop environment
# (instead of in Docker) which speeds up builds. Dockerfile.dev needs to be
# copied into dist to perform the build, since the dist directory is under
# .dockerignore.
image: packr
	docker build -t argocd-base --target argocd-base .
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 dist/packr build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-server ./cmd/argocd-server
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 dist/packr build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-application-controller ./cmd/argocd-application-controller
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 dist/packr build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-repo-server ./cmd/argocd-repo-server
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 dist/packr build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-util ./cmd/argocd-util
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 dist/packr build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd ./cmd/argocd
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 dist/packr build -v -ldflags '${LDFLAGS}' -o ${DIST_DIR}/argocd-darwin-amd64 ./cmd/argocd
	cp Dockerfile.dev dist
	docker build -t $(IMAGE_PREFIX)argocd:$(IMAGE_TAG) -f dist/Dockerfile.dev dist
else
image:
	docker build -t $(IMAGE_PREFIX)argocd:$(IMAGE_TAG) .
endif
	@if [ "$(DOCKER_PUSH)" = "true" ] ; then docker push $(IMAGE_PREFIX)argocd:$(IMAGE_TAG) ; fi

.PHONY: builder-image
builder-image:
	docker build -t $(IMAGE_PREFIX)argo-cd-ci-builder:$(IMAGE_TAG) --target builder .
	docker push $(IMAGE_PREFIX)argo-cd-ci-builder:$(IMAGE_TAG)

.PHONY: dep-ensure
dep-ensure: dist/dep
	dist/dep ensure -no-vendor

.PHONY: lint
lint: | dist/goimports dist/golangci-lint
	# golangci-lint does not do a good job of formatting imports
	dist/goimports -local github.com/argoproj/argo-cd -w `find . ! -path './vendor/*' ! -path './pkg/client/*' -type f -name '*.go'`
	dist/golangci-lint run --fix --verbose

.PHONY: build
build:
	go build -v `go list ./... | grep -v 'resource_customizations\|test/e2e'`

.PHONY: test
test:
	go test -v -covermode=count -coverprofile=coverage.out `go list ./... | grep -v "test/e2e"`

.PHONY: cover
cover:
	go tool cover -html=coverage.out

.PHONY: test-e2e
test-e2e: cli
	go test -v -timeout 10m ./test/e2e

.PHONY: start-e2e
start-e2e: cli
	killall goreman || true
	kubectl create ns argocd-e2e || true
	kubens argocd-e2e
	kustomize build test/manifests/base | kubectl apply -f -
	goreman start

# Cleans VSCode debug.test files from sub-dirs to prevent them from being
# included in packr boxes
.PHONY: clean-debug
clean-debug:
	-find -- '$(CURDIR)' -name debug.test | xargs rm -f

.PHONY: clean
clean: clean-debug
	-rm -rf -- '$(DIST_DIR)'

.PHONY: start
start:
	killall goreman || true
	kubens argocd
	goreman start

.PHONY: pre-commit
pre-commit: dep-ensure codegen build lint test

.PHONY: release-precheck
release-precheck: manifests
	@if [ "$(GIT_TREE_STATE)" != "clean" ]; then echo 'git tree state is $(GIT_TREE_STATE)' ; exit 1; fi
	@if [ -z "$(GIT_TAG)" ]; then echo 'commit must be tagged to perform release' ; exit 1; fi
	@if [ "$(GIT_TAG)" != "v`cat VERSION`" ]; then echo 'VERSION does not match git tag'; exit 1; fi

.PHONY: release
release: release-precheck pre-commit image release-cli

# code generation for CRDs
pkg/apis/%/generated.proto pkg/apis/%/generated.pb.go: pkg/apis/% | dist/go-to-protobuf
	@echo Code generation for $<...
	# NOTE: any dependencies of our types to the k8s.io apimachinery types should
	# be added to the --apimachinery-packages= option so that go-to-protobuf can
	# locate the types, but prefixed with a '-' so that go-to-protobuf will not
	# generate .proto files for it.
	PATH="$(DIST_DIR):$$PATH" go-to-protobuf \
		--go-header-file='$(CURDIR)/hack/custom-boilerplate.go.txt' \
		--packages='$(PACKAGE)/$<' \
		--proto-import='$(DIST_DIR)/protoc_include' \
		--proto-import='$(CURDIR)/vendor' \
		--apimachinery-packages=+k8s.io/apimachinery/pkg/util/intstr,+k8s.io/apimachinery/pkg/api/resource,+k8s.io/apimachinery/pkg/runtime/schema,+k8s.io/apimachinery/pkg/runtime,k8s.io/apimachinery/pkg/apis/meta/v1,k8s.io/api/core/v1

# code generation for proto files
%.pb.go %.pb.gw.go dist/swagger_out/%.swagger.json: %.proto pkg/apis/application/v1alpha1/generated.proto | dist/protoc dist/protoc-gen-gogofast dist/protoc-gen-grpc-gateway dist/protoc-gen-swagger
	@echo Code generation for $<...
	mkdir -p '$(DIST_DIR)/swagger_out'
	PATH="$(DIST_DIR):$$PATH" protoc \
		-I'$(CURDIR)' \
		-I'$(DIST_DIR)/protoc_include' \
		-I'$(CURDIR)/vendor' \
		-I"$$GOPATH/src" \
		-I'$(VENDOR_DIR)/github.com/grpc-ecosystem/grpc-gateway/third_party/googleapis' \
		-I'$(VENDOR_DIR)/github.com/gogo/protobuf' \
		--gogofast_out=plugins=grpc:"$$GOPATH/src" \
		--grpc-gateway_out=logtostderr=true:"$$GOPATH/src" \
		--swagger_out=logtostderr=true:'$(DIST_DIR)/swagger_out' \
		'$<'

# Generate combined Swagger spec for server
define EMPTY_CONSOLIDATED_SWAGGER
{
  "swagger": "2.0",
  "info": {
    "title": "Consolidate Services",
    "description": "Description of all APIs",
    "version": "version not set"
  },
  "paths": {}
}
endef
assets/swagger.json: $(addprefix dist/swagger_out/,$(addsuffix .swagger.json,$(basename $(SERVER_PROTO_FILES)))) | dist/swagger dist/jq
	@echo Consolidate Swagger specs into $@...
	$(file >dist/empty-consolidated-swagger.json,$(EMPTY_CONSOLIDATED_SWAGGER))
	dist/swagger mixin -c 24 dist/empty-consolidated-swagger.json $(sort $^) > dist/consolidated-swagger.json
	dist/jq -r 'del(.definitions[].properties[]? | select(."$$ref"!=null and .description!=null).description) | del(.definitions[].properties[]? | select(."$$ref"!=null and .title!=null).title)' dist/consolidated-swagger.json > '$@'

dist/dep:
	@echo Fetching $(@F)...
	@{ \
		mkdir -p -- '$(@D)' && \
		curl -Lf# -o '$@' -z '$@' 'https://github.com/golang/dep/releases/download/v0.5.3/dep-$(HOST_OS)-$(HOST_ARCH)' && \
		chmod +x -- '$@' && \
		'$@' version; \
	} || { rm -f -- '$@' && exit 1; }

dist/golangci-lint:
	@echo Fetching $(@F)...
	@{ \
		mkdir -p -- '$(@D)' && \
		curl -Lf# -o '$@.tar.gz' -z '$@.tar.gz' 'https://github.com/golangci/golangci-lint/releases/download/v1.16.0/golangci-lint-1.16.0-$(HOST_OS)-$(HOST_ARCH).tar.gz' && \
		tar --strip-components=1 -C dist -xf '$@.tar.gz' golangci-lint-1.16.0-$(HOST_OS)-$(HOST_ARCH)/golangci-lint && \
		'$@' --version; \
	} || { rm -f -- '$@.tar.gz' '$@' && exit 1; }

dist/goimports:
	@echo Building $(@F)...
	go build -o $@ ./vendor/golang.org/x/tools/cmd/$(@F)

dist/go-to-protobuf: dist/protoc dist/goimports dist/protoc-gen-gogo
	@echo Building $(@F)...
	go build -o $@ ./vendor/k8s.io/code-generator/cmd/$(@F)

dist/jq:
	@echo Fetching $(@F)...
	@{ \
		mkdir -p -- '$(@D)' && \
		curl -Lf# -o '$@' -z '$@' 'https://github.com/stedolan/jq/releases/download/jq-1.6/jq-$(subst linux-amd64,linux64,$(subst darwin-amd64,osx-amd64,$(HOST_OS)-$(HOST_ARCH)))' && \
		chmod +x -- '$@' && \
		'$@' --version; \
	} || { rm -f -- '$@' && exit 1; }

dist/packr:
	@echo Building $(@F)...
	go build -o $@ ./vendor/github.com/gobuffalo/packr/$(@F)

dist/protoc:
	@echo Fetching Protocol Buffers Compiler...
	@{ \
		mkdir -p -- '$(@D)' && \
		curl -Lf# -o 'dist/$(@F).zip' -z 'dist/$(@F).zip' 'https://github.com/protocolbuffers/protobuf/releases/download/v3.7.1/protoc-3.7.1-$(HOST_OS)-$(subst amd64,x86_64,$(subst darwin,osx,$(HOST_ARCH))).zip' && \
		rm -rf 'dist/$(@F)_unzip' && mkdir -p 'dist/$(@F)_unzip' && \
		unzip -o 'dist/$(@F).zip' -d 'dist/$(@F)_unzip' >&- && \
		mv -f 'dist/$(@F)_unzip/bin/$(@F)' dist && \
		rm -rf 'dist/$(@F)_include' && \
		mv -f 'dist/$(@F)_unzip/include' 'dist/$(@F)_include' && \
		rm -rf 'dist/$(@F)_unzip' && \
		'$@' --version; \
	} || { rm -rf 'dist/$(@F).zip' 'dist/$(@F)_unzip' '$@' 'dist/$(@F)_include' && exit 1; }

dist/protoc-gen-gogo:
	@echo Building $(@F)...
	go build -o $@ ./vendor/k8s.io/code-generator/cmd/go-to-protobuf/$(@F)

dist/protoc-gen-gogofast:
	@echo Building $(@F)...
	go build -o $@ ./vendor/github.com/gogo/protobuf/$(@F)

# protoc-gen-grpc-gateway is used to build <service>.pb.gw.go files from from <service>.proto files
dist/protoc-gen-grpc-gateway:
	@echo Building $(@F)...
	go build -o $@ ./vendor/github.com/grpc-ecosystem/grpc-gateway/$(@F)

# protoc-gen-swagger is used to build <service>.swagger.json files from from <service>.proto files
dist/protoc-gen-swagger:
	@echo Building $(@F)...
	go build -o $@ ./vendor/github.com/grpc-ecosystem/grpc-gateway/$(@F)

dist/swagger:
	@echo Fetching Go Swagger...
	@{ \
		mkdir -p -- '$(@D)' && \
		curl -Lf# -o '$@' -z '$@' 'https://github.com/go-swagger/go-swagger/releases/download/v0.19.0/swagger_$(HOST_OS)_$(HOST_ARCH)' && \
		chmod +x -- '$@' && \
		'$@' version; \
	} || { rm -f -- '$@' && exit 1; }
