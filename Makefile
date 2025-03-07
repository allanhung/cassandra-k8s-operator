# Copyright 2019 Orange
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# 	You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# 	See the License for the specific language governing permissions and
# limitations under the License.

################################################################################


# Name of this service/application
SERVICE_NAME := cassandra-k8s-operator

DOCKER_REPO_BASE ?= orangeopensource
#we could want to separate registry for branches
DOCKER_REPO_BASE_TEST ?= orangeopensource

# Docker image name for this project
IMAGE_NAME := $(SERVICE_NAME)

BUILD_IMAGE ?= orangeopensource/casskop-build

TELEPRESENCE_REGISTRY:=datawire
KUBESQUASH_REGISTRY:=

MINIKUBE_CONFIG ?= ~/.minikube
MINIKUBE_CONFIG_MOUNT ?= /home/circleci/.minikube

# Repository url for this project
#in gitlab CI_REGISTRY_IMAGE=repo/path/name:tag
ifdef CI_REGISTRY_IMAGE
	REPOSITORY := $(CI_REGISTRY_IMAGE)
else
	REPOSITORY := $(DOCKER_REPO_BASE)/$(IMAGE_NAME)
endif

# Branch is used for the docker image version
ifdef CIRCLE_BRANCH
	#removing / for fork which lead to docker error
	BRANCH := $(subst /,-,$(CIRCLE_BRANCH))
else
  ifdef CIRCLE_TAG
		BRANCH := $(CIRCLE_TAG)
	else
		BRANCH=$(shell git rev-parse --abbrev-ref HEAD)
	endif
endif

#Operator version is managed in go file
#BaseVersion is for dev docker image tag
BASEVERSION := $(shell cat version/version.go | awk -F\" '/Version =/ { print $$2}')
#Version is for binary, docker image and helm

ifdef CIRCLE_TAG
	VERSION := ${BRANCH}
else
	VERSION := $(BASEVERSION)-${BRANCH}
endif

HELM_VERSION := $(shell cat helm/cassandra-operator/Chart.yaml| grep version | awk -F"version: " '{print $$2}')

#si branche master, on pousse le tag latest
ifeq ($(CIRCLE_BRANCH),master)
	PUSHLATEST := true
endif

# Compute image to uses for e2e tests
ifdef CIRCLE_BRANCH
  ifeq ($(CIRCLE_BRANCH),master)
	  E2EIMAGE := $(DOCKER_REPO_BASE)/$(IMAGE_NAME):$(VERSION)
  else
	  E2EIMAGE := $(DOCKER_REPO_BASE_TEST)/$(IMAGE_NAME):$(VERSION)
  endif
else
  ifdef CIRCLE_TAG
	  E2EIMAGE := $(DOCKER_REPO_BASE)/$(IMAGE_NAME):$(BRANCH)
  else
		ifeq ($(BRANCH),master)
	    E2EIMAGE := $(DOCKER_REPO_BASE)/$(IMAGE_NAME):latest
    else
	    E2EIMAGE := $(DOCKER_REPO_BASE_TEST)/$(IMAGE_NAME):$(VERSION)
    endif
  endif
endif

e2eimage:
	echo $(E2EIMAGE)

params:
	@echo "CIRCLE_BRANCH = '$(CIRCLE_BRANCH)'"
	@echo "CIRCLE_TAG = '$(CIRCLE_TAG)'"
	@echo "Version = '$(VERSION)'"
	@echo "E2EIMAGE = '$(E2EIMAGE)'"

# Shell to use for running scripts
SHELL := $(shell which bash)

# Get docker path or an empty string
DOCKER := $(shell command -v docker)

# Get the main unix group for the user running make (to be used by docker-compose later)
GID := $(shell id -g)

# Get the unix user id for the user running make (to be used by docker-compose later)
UID := $(shell id -u)

# Commit hash from git
COMMIT=$(shell git rev-parse HEAD)


# CMDs
UNIT_TEST_CMD := KUBERNETES_CONFIG=`pwd`/config/test-kube-config.yaml POD_NAME=test go test --cover --coverprofile=coverage.out `go list ./... | grep -v e2e` > test-report.out
UNIT_TEST_CMD_WITH_VENDOR := KUBERNETES_CONFIG=`pwd`/config/test-kube-config.yaml POD_NAME=test go test -mod=vendor --cover --coverprofile=coverage.out `go list -mod=vendor ./... | grep -v e2e` > test-report.out 
UNIT_TEST_COVERAGE := go tool cover -html=coverage.out -o coverage.html
GO_GENERATE_CMD := go generate `go list ./... | grep -v /vendor/`
GO_LINT_CMD := golint `go list ./... | grep -v /vendor/`
MOCKS_CMD := go generate ./mocks

# environment dirs
DEV_DIR := docker/circleci
APP_DIR := build/Dockerfile

OPERATOR_SDK_VERSION=v0.9.0
# workdir
WORKDIR := /go/cassandra-k8s-operator

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
	GOOS = linux
endif
ifeq ($(UNAME_S),Darwin)
	GOOS = darwin
endif

# Some other usefule make file for interracting with kubernetes 
include kube.mk

#
#
################################################################################

# The default action of this Makefile is to build the development docker image
.PHONY: default
default: build

.DEFAULT_GOAL := help
help:	
	@grep -E '(^[a-zA-Z_-]+:.*?##.*$$)|(^##)' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}{printf "\033[32m%-30s\033[0m %s\n", $$1, $$2}' | sed -e 's/\[32m##/[33m/'

## Example section
example_target: ## Description for example target
	@does something

get-baseversion:
	@echo $(BASEVERSION)
get-version:
	@echo $(VERSION)

clean:
	@rm -rf $(OUT_BIN) || true
	@rm -f apis/cassandracluster/v1alpha1/zz_generated.deepcopy.go || true

helm-package:
	@echo Packaging $(HELM_VERSION)
	helm package helm/cassandra-operator
	mv cassandra-operator-$(HELM_VERSION).tgz docs/helm
	helm repo index docs/helm/

# Build cassandra-k8s-operator executable file in local go env
.PHONY: build
build:
	echo "Generate zzz-deepcopy objects"
	operator-sdk version
	operator-sdk generate k8s
	echo "Build Cassandra Operator"
	operator-sdk build $(REPOSITORY):$(VERSION) --image-build-args "--build-arg https_proxy=$$https_proxy --build-arg http_proxy=$$http_proxy"
ifdef PUSHLATEST
	docker tag $(REPOSITORY):$(VERSION) $(REPOSITORY):latest
endif
#	

# Run a shell into the development docker image
.PHONY: docker-build
docker-build: ## Build the Operator and it's Docker Image
	echo "Generate zzz-deepcopy objects"
	docker run --rm -v $(PWD):$(WORKDIR) -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build --env GO111MODULE=on --env https_proxy=$(https_proxy) --env http_proxy=$(http_proxy) $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c 'operator-sdk generate k8s'
	echo "Build Cassandra Operator. Using cache from "$(shell go env GOCACHE)
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v $(PWD):$(WORKDIR) -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build --env GO111MODULE=on --env https_proxy=$(https_proxy) --env http_proxy=$(http_proxy) $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c 'operator-sdk build $(REPOSITORY):$(VERSION) --image-build-args "--build-arg https_proxy=$$https_proxy --build-arg http_proxy=$$http_proxy"'
ifdef PUSHLATEST
	docker tag $(REPOSITORY):$(VERSION) $(REPOSITORY):latest
endif

# Build the docker development environment
.PHONY: build-ci-image
build-ci-image: deps-development
	docker build --cache-from $(BUILD_IMAGE):latest \
	  --build-arg OPERATOR_SDK_VERSION=$(OPERATOR_SDK_VERSION) \
		-t $(BUILD_IMAGE):latest \
		-t $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) \
		-f $(DEV_DIR)/Dockerfile \
		.

.PHONY: push-ci-image
push-ci-image: deps-development
	docker push $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION)
ifdef PUSHLATEST
	docker push $(BUILD_IMAGE):latest
endif


pipeline:
	docker run -ti --rm --privileged -v $(PWD):/go/src/github.com/Orange-OpenSource/cassandra-k8s-operator -w /go/src/github.com/Orange-OpenSource/cassandra-k8s-operator \
  --env https_proxy=$(https_proxy) --env http_proxy=$(http_proxy) \
	$(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) bash

pipeline-e2e:
	docker run -ti --rm --privileged -v $(PWD):/source -w /source \
	$(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) bash

circleci-process:
	circleci config process .circleci/config.yml

circleci-validate:
	circleci config validate

# Run a shell into the development docker image
.PHONY: shell
shell: docker-dev-build
	docker run  --env GO111MODULE=on -ti --rm -v ~/.kube:/.kube:ro -v $(PWD):$(WORKDIR) --name $(SERVICE_NAME) $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash


debug-port-forward:
	kubectl port-forward `kubectl get pod -l app=cassandra-k8s-operator -o jsonpath="{.items[0].metadata.name}"` 40000:40000

debug-pod-logs:
	kubectl logs -f `kubectl get pod -l app=cassandra-k8s-operator -o jsonpath="{.items[0].metadata.name}"`

debug-telepresence:
	export TELEPRESENCE_REGISTRY=$(TELEPRESENCE_REGISTRY) ; \
	echo "execute : cat cassandra-operator.env" ; \
  sudo mkdir -p /var/run/secrets/kubernetes.io ; \
	sudo ln -s /tmp/known/var/run/secrets/kubernetes.io/serviceaccount /var/run/secrets/kubernetes.io/ ; \
	tdep=$(shell kubectl get deployment -l app=cassandra-operator -o jsonpath='{.items[0].metadata.name}') ; \
	telepresence --swap-deployment $$tdep --mount=/tmp/known --env-file cassandra-operator.env

debug-telepresence-with-alias:
	export TELEPRESENCE_REGISTRY=$(TELEPRESENCE_REGISTRY) ; \
	echo "execute : cat cassandra-operator.env" ; \
  sudo mkdir -p /var/run/secrets/kubernetes.io ; \
	sudo ln -s /tmp/known/var/run/secrets/kubernetes.io/serviceaccount /var/run/secrets/kubernetes.io/ ; \
	tdep=$(shell kubectl get deployment -l app=cassandra-operator -o jsonpath='{.items[0].metadata.name}') ; \
	telepresence --swap-deployment $$tdep --mount=/tmp/known --env-file cassandra-operator.env \
	--also-proxy 10.40.0.0/16
#	--also-proxy 172.18.0.0/16


debug-kubesquash:
	kubesquash --container-repo $(KUBESQUASH_REGISTRY)


# Run the development environment (in local go env) in the background using local ~/.kube/config
.PHONY: run
run:
	export POD_NAME=cassandra-k8s-operator; \
	operator-sdk up local


.PHONY: push
push:
	docker push $(REPOSITORY):$(VERSION)
ifdef PUSHLATEST
	docker push $(REPOSITORY):latest
endif

.PHONY: tag
tag:
	git tag $(VERSION)

.PHONY: publish
publish:
	@COMMIT_VERSION="$$(git rev-list -n 1 $(VERSION))"; \
	docker tag $(REPOSITORY):"$$COMMIT_VERSION" $(REPOSITORY):$(VERSION)
	docker push $(REPOSITORY):$(VERSION)
ifdef PUSHLATEST
	docker push $(REPOSITORY):latest
endif

.PHONY: release
release: tag image publish

# Test stuff in dev
.PHONY: docker-unit-test
docker-unit-test:
	docker run  --env GO111MODULE=on --rm -v $(PWD):$(WORKDIR)  -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c '$(UNIT_TEST_CMD); cat test-report.out; $(UNIT_TEST_COVERAGE)'
.PHONY: docker-unit-test-with-vendor
docker-unit-test-with-vendor:
	docker run  --env GO111MODULE=on --rm -v $(PWD):$(WORKDIR)  -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c '$(UNIT_TEST_CMD_WITH_VENDOR); cat test-report.out; $(UNIT_TEST_COVERAGE)'

.PHONY: unit-test
unit-test:
	$(UNIT_TEST_CMD) && echo "success!" || { echo "failure!"; cat test-report.out; exit 1; }
	cat test-report.out 
	$(UNIT_TEST_COVERAGE)

.PHONY: unit-test-with-vendor
unit-test-with-vendor:
	$(UNIT_TEST_CMD_WITH_VENDOR) && echo "success!" || { echo "failure!"; cat test-report.out; exit 1; }
	cat test-report.out 
	$(UNIT_TEST_COVERAGE)


.PHONY: docker-go-lint
docker-go-lint:
	docker run  --env GO111MODULE=on -ti --rm -v $(PWD):$(WORKDIR) -u $(UID):$(GID) --name $(SERVICE_NAME) $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/sh -c '$(GO_LINT_CMD)'

# golint is not fully supported by modules yet - https://github.com/golang/lint/issues/409
.PHONY: go-lint
go-lint:
	$(GO_LINT_CMD)


.PHONY: mocks
mocks: 
	docker run --env GO111MODULE=on -ti --rm -v $(PWD):$(WORKDIR) -u $(UID):$(GID) --name $(SERVICE_NAME) $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/sh -c '$(MOCKS_CMD)'

.PHONY: deps-development
# Test if the dependencies we need to run this Makefile are installed
deps-development:
ifndef DOCKER
	@echo "Docker is not available. Please install docker"
	@exit 1
endif


#Generate dep for graph
UNAME := $(shell uname -s)
dep-graph:
ifeq ($(UNAME), Darwin)
# do something osxsd
	dep status -dot | dot -T png | open -f -a /Applications/Preview.app
endif
ifeq ($(UNAME), Linux)
# do something osx
	dep status -dot | dot -T png | display	
endif


count:
	git ls-files | xargs wc -l


image:
	echo $(REPOSITORY):$(VERSION)

export CGO_ENABLED:=0

.PHONY: e2e e2e-scaleup docker-e2e
e2e:
	operator-sdk test local ./test/e2e --image $(E2EIMAGE) --go-test-flags "-v -timeout 40m" || { kubectl get events --all-namespaces --sort-by .metadata.creationTimestamp ; exit 1; }

docker-e2e:
	docker run --env GO111MODULE=on --rm -v $(PWD):$(WORKDIR) -v $(KUBECONFIG):/root/.kube/config -v $(MINIKUBE_CONFIG):$(MINIKUBE_CONFIG_MOUNT)  $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c 'operator-sdk test local ./test/e2e --debug --image $(E2EIMAGE) --go-test-flags "-v -timeout 40m"' || { kubectl get events --all-namespaces --sort-by .metadata.creationTimestamp ; exit 1; }

e2e-scaleup:
	operator-sdk test local ./test/e2e --image $(E2EIMAGE) --go-test-flags "-v -timeout 40m -run ^TestCassandraCluster$$/^group$$/^ClusterScaleUp$$" || { kubectl get events --all-namespaces --sort-by .metadata.creationTimestamp ; exit 1; }

e2e-scaledown:
	operator-sdk test local ./test/e2e --image $(E2EIMAGE) --go-test-flags "-v -timeout 40m -run ^TestCassandraCluster$$/^group$$/^ClusterScaleDown$$" || { kubectl get events --all-namespaces --sort-by .metadata.creationTimestamp ; exit 1; }

e2e-empty:
	operator-sdk test local ./test/e2e --image $(E2EIMAGE) --go-test-flags "-v -timeout 40m -run ^empty$$" 


.PHONY: e2e-test-fix e2e-tet-fix-arg docker-e2e-test-fix docker-e2e-test-fix-arg
e2e-test-fix:
	operator-sdk test local ./test/e2e --debug --image $(E2EIMAGE) --go-test-flags "-v -timeout 60m" --namespace cassandra-e2e || { kubectl get events --all-namespaces --sort-by .metadata.creationTimestamp ; exit 1; }

ifeq (e2e-test-fix-arg,$(firstword $(MAKECMDGOALS)))
  E2E_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  $(eval $(E2E_ARGS):;@:)
endif
e2e-test-fix-arg:
ifeq ($(E2E_ARGS),)	
	@echo "args are: RollingRestart ; ClusterScaleDown ; ClusterScaleUp ; ClusterScaleDownSimple" && exit 1
endif
	operator-sdk test local ./test/e2e --debug --image $(E2EIMAGE) --go-test-flags "-v -mod=vendor -timeout 60m -run ^TestCassandraCluster$$/^group$$/^$(E2E_ARGS)$$" --namespace cassandra-e2e || { kubectl get events --all-namespaces --sort-by .metadata.creationTimestamp ; exit 1; }

docker-e2e-test-fix:
	docker run --env GO111MODULE=on --rm -v $(PWD):$(WORKDIR)  -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build -v $(KUBECONFIG):/root/.kube/config -v $(MINIKUBE_CONFIG):$(MINIKUBE_CONFIG_MOUNT)  $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c 'operator-sdk test local ./test/e2e --debug --image $(E2EIMAGE) --go-test-flags "-v -mod=vendor -timeout 60m" --namespace cassandra-e2e'

#execute Test filter based on given Regex
ifeq (docker-e2e-test-fix-arg,$(firstword $(MAKECMDGOALS)))
  # use the rest as arguments for "run"
  E2E_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  # ...and turn them into do-nothing targets
  $(eval $(E2E_ARGS):;@:)
endif
docker-e2e-test-fix-arg:
ifeq ($(E2E_ARGS),)	
	@echo "args are: RollingRestart ; ClusterScaleDown ; ClusterScaleUp ; ClusterScaleDownSimple" && exit 1
endif
	docker run --rm --env GO111MODULE=on -v $(PWD):$(WORKDIR)  -v $(GOPATH)/pkg/mod:/go/pkg/mod -v $(shell go env GOCACHE):/root/.cache/go-build -v $(KUBECONFIG):/root/.kube/config -v $(MINIKUBE_CONFIG):$(MINIKUBE_CONFIG_MOUNT)  $(BUILD_IMAGE):$(OPERATOR_SDK_VERSION) /bin/bash -c 'operator-sdk test local ./test/e2e --debug --image $(E2EIMAGE) --go-test-flags "-v -timeout 60m -run ^TestCassandraCluster$$/^group$$/^$(E2E_ARGS)$$" --namespace cassandra-e2e' || { kubectl get events --all-namespaces --sort-by .metadata.creationTimestamp ; exit 1; }

.PHONY: e2e-test-fix
e2e-test-fix-scale-down:
	operator-sdk test local ./test/e2e --image $(E2EIMAGE) --go-test-flags "-v -timeout 60m -run ^TestCassandraCluster$$/^group$$/^ClusterScaleDown$$" --namespace cassandra-e2e || { kubectl get events --all-namespaces --sort-by .metadata.creationTimestamp ; exit 1; }



configure-psp:
	kubectl get clusterrole psp:cassie -o yaml
	kubectl -n cassandra get rolebindings.rbac.authorization.k8s.io psp:sa:cassie -o yaml
	kubectl -n cassandra get rolebindings.rbac.authorization.k8s.io psp:sa:cassie -o yaml | grep -vE '(annotations|creationTimestamp|resourceVersion|uid|selfLink|last-applied-configuration)' | sed 's/cassandra/cassandra-e2e/' | kubectl apply -f -


ifeq (cassandra-stress,$(firstword $(MAKECMDGOALS)))
  # use the rest as arguments for "run"
  STRESS_TYPE := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  # ...and turn them into do-nothing targets
  $(eval $(STRESS_TYPE):;@:)
endif

REPLICATION_FACTOR ?= 1
DC ?= dc1
USERNAME =? cassandra
PASSWORD =? cassandra

cassandra-stress:
	kubectl delete configmap cassandra-stress-$(STRESS_TYPE) || true
	cp tests/cassandra-stress/$(STRESS_TYPE)_stress.yaml /tmp/
	echo Using replication factor $(REPLICATION_FACTOR) with DC $(DC) in cassandra-stress profile file
	sed -i -e "s/'dc1': '3'/'$(DC)': '$(REPLICATION_FACTOR)'/" /tmp/$(STRESS_TYPE)_stress.yaml
	kubectl create configmap cassandra-stress-$(STRESS_TYPE) --from-file=/tmp/$(STRESS_TYPE)_stress.yaml
	kubectl delete -f tests/cassandra-stress/cassandra-stress-$(STRESS_TYPE).yaml --wait=false || true
	while kubectl get pod cassandra-stress-$(STRESS_TYPE)>/dev/null; do echo -n "."; sleep 1 ; done
	cp tests/cassandra-stress/cassandra-stress-$(STRESS_TYPE).yaml /tmp/
	sed -i -e 's/user=[a-zA-Z]* password=[a-zA-Z]*/user=$(USERNAME) password=$(PASSWORD)/' /tmp/cassandra-stress-$(STRESS_TYPE).yaml
ifdef CASSANDRA_IMAGE
	echo "using Cassandra image $(CASSANDRA_IMAGE)"
	sed -i -e 's#orangeopensource/cassandra-image.*#$(CASSANDRA_IMAGE)#g' /tmp/cassandra-stress-$(STRESS_TYPE).yaml
endif

ifdef CASSANDRA_NODE
	sed -i -e 's/cassandra-demo/$(CASSANDRA_NODE)/g' /tmp/cassandra-stress-$(STRESS_TYPE).yaml
else
  ifneq ($(and $(CLUSTER_NAME),$(DC),$(RACK)),)
	sed -i -e 's/cassandra-demo/$(CLUSTER_NAME)-$(DC)-$(RACK)-0.$(CLUSTER_NAME)/g' /tmp/cassandra-stress-$(STRESS_TYPE).yaml
  endif

  ifdef CLUSTER_NAME
	sed -i -e 's/cassandra-demo/$(CLUSTER_NAME)/g' /tmp/cassandra-stress-$(STRESS_TYPE).yaml
  endif
endif

ifdef CONSISTENCY_LEVEL
	sed -i -e 's/cl=one/cl=$(CONSISTENCY_LEVEL)/g' /tmp/cassandra-stress-$(STRESS_TYPE).yaml
endif
	kubectl apply -f /tmp/cassandra-stress-$(STRESS_TYPE).yaml
