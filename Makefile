GO ?= go
PNPM ?= pnpm
STYLUA ?= stylua
LUACHECK ?= luacheck
NVIM_BIN ?= nvim
GOLANGCI_LINT := github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0
GO_MODULES := apps/mcp apps/companion
LUA_PATHS := lua plugin tests apps/scripts
VERSION ?= $(shell python3 -c 'import json; print(json.load(open("release.json"))["version"])')

.PHONY: build build-mcp build-all build-companion build-companion-ui test test-lua test-lua-unit test-companion vet check check-all release clean
.PHONY: format format-lua format-go format-web lint lint-lua lint-go lint-web hooks

format: format-lua format-go format-web

format-lua:
	$(STYLUA) $(LUA_PATHS)
	$(NVIM_BIN) --headless -u NONE -i NONE -l apps/scripts/lua-spacing.lua $(LUA_PATHS)

format-go:
	@set -e; for module in $(GO_MODULES); do \
		$(GO) -C $$module run $(GOLANGCI_LINT) run --fix ./...; \
		$(GO) -C $$module run $(GOLANGCI_LINT) fmt ./...; \
	done

format-web:
	$(PNPM) --dir apps/companion/web run format

lint: lint-lua lint-go lint-web

lint-lua:
	$(STYLUA) --check $(LUA_PATHS)
	$(NVIM_BIN) --headless -u NONE -i NONE -l apps/scripts/lua-spacing.lua --check $(LUA_PATHS)
	$(LUACHECK) $(LUA_PATHS)

lint-go:
	@set -e; for module in $(GO_MODULES); do \
		$(GO) -C $$module run $(GOLANGCI_LINT) fmt --diff ./...; \
		$(GO) -C $$module vet ./...; \
		$(GO) -C $$module run $(GOLANGCI_LINT) run ./...; \
	done

lint-web:
	$(PNPM) --dir apps/companion/web run lint
	$(PNPM) --dir apps/companion/web run typecheck
	$(PNPM) --dir apps/companion/web run format:check

hooks:
	install -m 755 .githooks/pre-commit "$$(git rev-parse --git-path hooks)/pre-commit"

build: build-mcp

build-mcp:
	CGO_ENABLED=0 $(GO) -C apps/mcp build -ldflags "-X main.version=$(VERSION)" -o aero-mcp ./cmd/aero-mcp

build-all: build-mcp build-companion

test:
	$(GO) -C apps/mcp test ./...

test-lua: build-all
	python3 tests/run.py

test-lua-unit:
	python3 tests/run.py --unit

build-companion-ui:
	$(PNPM) --dir apps/companion/web install --frozen-lockfile
	$(PNPM) --dir apps/companion/web run build

build-companion: build-companion-ui
	CGO_ENABLED=0 $(GO) -C apps/companion build -ldflags "-X main.version=$(VERSION)" -o aero-companion .

test-companion: build-companion build-mcp
	nvim --headless -u NONE -l tests/companion_install.lua
	nvim --headless -u NONE -l tests/companion.lua
	nvim --headless -u NONE -l tests/companion_lifecycle.lua
	AERO_MCP_EXECUTABLE="$(CURDIR)/apps/mcp/aero-mcp" nvim --headless -u NONE -l tests/companion_tasks.lua
	nvim --headless -u NONE -l tests/companion_managed.lua
	$(GO) -C apps/companion test -race ./...
	$(GO) -C apps/companion vet ./...
	$(PNPM) --dir apps/companion/web test

vet:
	$(GO) -C apps/mcp vet ./...

check: test vet

check-all: check test-companion test-lua

release: build-companion-ui
	GO="$(GO)" python3 apps/scripts/build-release.py $(if $(TAG),--tag "$(TAG)")

clean:
	rm -f apps/mcp/aero-mcp apps/mcp/aero-mcp.exe
	rm -f apps/companion/aero-companion apps/companion/aero-companion.exe
