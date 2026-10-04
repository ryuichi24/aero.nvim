GO ?= go

.PHONY: build test vet check clean

build:
	CGO_ENABLED=0 $(GO) -C mcp build -o aero-mcp ./cmd/aero-mcp

test:
	$(GO) -C mcp test ./...

vet:
	$(GO) -C mcp vet ./...

check: test vet

clean:
	rm -f mcp/aero-mcp mcp/aero-mcp.exe
