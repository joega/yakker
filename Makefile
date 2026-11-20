GO ?= go
LDFLAGS ?= -s -w
TARGET_ARCH ?= $(shell $(GO) env GOARCH)

.PHONY: build test check release install clean

# Static Linux binaries without local source paths or Git metadata.
build:
	CGO_ENABLED=0 $(GO) build -trimpath -buildvcs=false -ldflags="$(LDFLAGS)" -o yakker-controller ./cmd/yakker-controller
	CGO_ENABLED=0 $(GO) build -trimpath -buildvcs=false -ldflags="$(LDFLAGS)" -o yakker ./cmd/yakker

test:
	$(GO) test ./...

# These checks work on Linux without an installed Omarchy desktop.
check:
	test -z "$$(gofmt -l cmd internal tools)"
	$(GO) vet ./...
	$(GO) mod verify
	$(GO) test -race ./...

release:
	$(GO) run ./tools/release --arch "$(TARGET_ARCH)" --output dist

install: build
	./yakker install

clean:
	$(GO) clean
	$(RM) yakker-controller yakker
