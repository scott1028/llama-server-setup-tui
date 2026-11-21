NAME    := llama-server-setup-tui
# CI passes VERSION=<tag>; locally it comes from git, e.g. v0.1.0 or v0.1.0-1-g93869a5-dirty.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
ARCH    ?= $(shell uname -m)
SHC     ?= shc
BIN     := dist/$(NAME)-$(VERSION)-linux-$(ARCH)

SHELL       := /bin/bash
.SHELLFLAGS := -eo pipefail -c

.PHONY: build test checksum clean

build: $(BIN)

# shc cannot parse "#!/usr/bin/env bash", so build from a /bin/bash copy.
# -r: runs on other machines; -static: no glibc version dependency.
$(BIN): $(NAME).sh
	@command -v $(SHC) >/dev/null || { echo "shc not found. Install it, e.g. 'sudo apt install shc'." >&2; exit 1; }
	mkdir -p build dist
	sed '1s|^#!.*|#!/bin/bash|' $< > build/$(NAME).sh
	CFLAGS=-static $(SHC) -r -f build/$(NAME).sh -o $@
	file $@

# A fake llama prints its args; a config next to the binary skips the TUI.
test: $(BIN)
	rm -rf build/smoke
	mkdir -p build/smoke/bin
	printf '#!/bin/sh\necho "llama $$*"\n' > build/smoke/bin/llama
	chmod +x build/smoke/bin/llama
	cp $(BIN) build/smoke/
	printf '%s\n' '--model /models/test.gguf' '--no-mmproj' > build/smoke/llama-server.args
	output=$$(PATH="$(CURDIR)/build/smoke/bin:$$PATH" build/smoke/$(notdir $(BIN)) --port 8899); \
	echo "$$output"; \
	[[ $$output == *"llama serve --host 127.0.0.1"*"--model /models/test.gguf --no-mmproj --port 8899" ]]

checksum: $(BIN)
	cd dist && sha256sum $(notdir $(BIN)) > $(notdir $(BIN)).sha256

clean:
	rm -rf build dist
