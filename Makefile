GO ?= go
PNPM ?= pnpm
VERSION ?= $(shell python3 -c 'import json; print(json.load(open("release.json"))["version"])')

.PHONY: build build-mcp build-all build-companion build-companion-ui test test-companion vet check check-all release clean

build: build-mcp

build-mcp:
	CGO_ENABLED=0 $(GO) -C apps/mcp build -ldflags "-X main.version=$(VERSION)" -o aero-mcp ./cmd/aero-mcp

build-all: build-mcp build-companion

test:
	$(GO) -C apps/mcp test ./...

build-companion-ui:
	$(PNPM) --dir apps/companion/web install --frozen-lockfile
	$(PNPM) --dir apps/companion/web run build

build-companion: build-companion-ui
	CGO_ENABLED=0 $(GO) -C apps/companion build -ldflags "-X main.version=$(VERSION)" -o aero-companion .

test-companion: build-companion
	nvim --headless -u NONE -l tests/companion_install.lua
	nvim --headless -u NONE -l tests/companion.lua
	nvim --headless -u NONE -l tests/companion_managed.lua
	$(GO) -C apps/companion test -race ./...
	$(GO) -C apps/companion vet ./...
	$(PNPM) --dir apps/companion/web test

vet:
	$(GO) -C apps/mcp vet ./...

check: test vet

check-all: check test-companion

release: build-companion-ui
	GO="$(GO)" python3 apps/scripts/build-release.py $(if $(TAG),--tag "$(TAG)")

clean:
	rm -f apps/mcp/aero-mcp apps/mcp/aero-mcp.exe
	rm -f apps/companion/aero-companion apps/companion/aero-companion.exe
