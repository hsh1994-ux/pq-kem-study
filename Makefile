# Comparative study of post-quantum KEMs -- top-level driver.
# Runs on x86-64 and ARM64 Linux (natively or in docker/Dockerfile).

BUILD_DIR ?= $(CURDIR)/build
export BUILD_DIR

CC      ?= cc
CFLAGS  ?= -O2 -g
CFLAGS  += -std=c11 -Wall -Wextra -D_GNU_SOURCE
OQS      = $(BUILD_DIR)/liboqs-$*
OQS_LINK = $(OQS)/lib/liboqs.a -lpthread
HDRS     = $(wildcard common/*.h)

TIERS    = ref opt
TOOLS    = $(foreach t,$(TIERS),bin/kemtool-$(t))

.PHONY: help deps tools sysinfo kat clean distclean

help:
	@echo "Targets:"
	@echo "  deps       build OpenSSL 3.5, liboqs (ref/opt/ct) and oqs-provider into \$$BUILD_DIR"
	@echo "  tools      compile the C harnesses in bin/"
	@echo "  kat        E4: correctness and interoperability checks"
	@echo "  sysinfo    print the machine metadata recorded in every results file"
	@echo "  clean      remove compiled tools (keeps dependencies)"
	@echo "  distclean  remove everything in \$$BUILD_DIR"

deps:
	scripts/build_deps.sh

tools: $(TOOLS)

bin/kemtool-%: kat/kemtool.c $(HDRS)
	@mkdir -p bin
	$(CC) $(CFLAGS) -DBUILD_TIER='"$*"' -I$(OQS)/include $< -o $@ $(OQS_LINK)

kat: tools
	kat/run_e4.py

sysinfo:
	@scripts/sysinfo.sh

clean:
	rm -rf bin

distclean: clean
	rm -rf $(BUILD_DIR)
