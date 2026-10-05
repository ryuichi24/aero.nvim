GO ?= go

.PHONY: build test vet check clean

build:
	VERSION=$$(python3 -c 'import json; print(json.load(open("mcp/release.json"))["version"])') && \
		CGO_ENABLED=0 $(GO) -C mcp build -ldflags "-X main.version=$$VERSION" -o aero-mcp ./cmd/aero-mcp

test:
	$(GO) -C mcp test ./...

vet:
	$(GO) -C mcp vet ./...

check: test vet

clean:
	rm -f mcp/aero-mcp mcp/aero-mcp.exe
