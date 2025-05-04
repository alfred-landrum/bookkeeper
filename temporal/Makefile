
DOCKER_REGISTRY ?=
DOCKER_IMAGE_TAG := $(shell whoami | tr -d " ")-local-$(shell git rev-parse --short HEAD)
DOCKER_IMAGE_TAG := $(shell whoami | tr -d " ")-local-$(shell git rev-parse --short HEAD)
DOCKER_PLATFORM ?= linux/amd64,linux/arm64
DOCKER_BUILD_LOCAL ?= docker buildx build --ssh default="$$SSH_AUTH_SOCK" --output type=docker --platform $(DOCKER_PLATFORM)

docker-build/%:
	@if ! ssh-add -L -q > /dev/null; then echo >&2 'Did you forget to run: eval $$(ssh-agent); ssh-add ~/.ssh/my-private-key?'; exit 1; fi
	$(DOCKER_BUILD_LOCAL) -f temporal/Dockerfile --target $* --tag $(DOCKER_REGISTRY)/$*:$(DOCKER_IMAGE_TAG) .

docker-push/%:
	@if ! ssh-add -L -q > /dev/null; then echo >&2 'Did you forget to run: eval $$(ssh-agent); ssh-add ~/.ssh/my-private-key?'; exit 1; fi
	$(DOCKER_BUILD_LOCAL) -f temporal/Dockerfile --target $* --tag $(DOCKER_REGISTRY)/$*:$(DOCKER_IMAGE_TAG) --push .

docker-build: docker-build/bookkeeper-wal

docker-push: docker-push/bookkeeper-wal
