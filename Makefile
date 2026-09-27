# Comparative study of post-quantum KEMs -- top-level driver.
# Runs on x86-64 and ARM64 Linux (natively or in docker/Dockerfile).

BUILD_DIR ?= $(CURDIR)/build
export BUILD_DIR

.PHONY: help deps sysinfo clean distclean

help:
	@echo "Targets:"
	@echo "  deps       build OpenSSL 3.5, liboqs (ref/opt/ct) and oqs-provider into \$$BUILD_DIR"
	@echo "  sysinfo    print the machine metadata recorded in every results file"
	@echo "  clean      remove compiled tools (keeps dependencies)"
	@echo "  distclean  remove everything in \$$BUILD_DIR"

deps:
	scripts/build_deps.sh

sysinfo:
	@scripts/sysinfo.sh

clean:
	rm -rf bin

distclean: clean
	rm -rf $(BUILD_DIR)
