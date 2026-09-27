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
OSSL     = $(BUILD_DIR)/openssl
OSSL_LINK = -L$(OSSL)/lib -Wl,-rpath,$(OSSL)/lib -lcrypto
TOOLS    = $(foreach t,$(TIERS),bin/kemtool-$(t) bin/bench_kem-$(t)) bin/bench_ossl bin/hs_client \
           $(foreach t,$(TIERS),bin/dudect_kem-$(t)) bin/dudect_planted

.PHONY: help deps tools sysinfo kat bench tls ct kyber figures report all quick demo clean distclean

help:
	@echo "Targets:"
	@echo "  deps       build OpenSSL 3.5, liboqs (ref/opt/ct) and oqs-provider into \$$BUILD_DIR"
	@echo "  tools      compile the C harnesses in bin/"
	@echo "  kat        E4: correctness and interoperability checks"
	@echo "  bench      E1: keygen/encaps/decaps timing, sizes, stack (COOLDOWN=30 on laptops)"
	@echo "  tls        E2: TLS 1.3 handshakes under emulated RTT/loss (rootless netns)"
	@echo "  ct         E3: dudect timing tests, KyberSlash control, DIV scan, Valgrind"
	@echo "  figures    figures/ and report/tables/ from the newest results"
	@echo "  report     figures + report/main.pdf (needs LaTeX)"
	@echo "  all        kat bench tls ct figures (the full study, ~1-2 h)"
	@echo "  quick      the same as smoke tests (~10 min, results not for the report)"
	@echo "  demo       the mini-conference demo"
	@echo "  sysinfo    print the machine metadata recorded in every results file"
	@echo "  clean      remove compiled tools (keeps dependencies)"
	@echo "  distclean  remove everything in \$$BUILD_DIR"
	@echo "Add QUICK=1 to any experiment for a fast smoke test (not for the report)."

deps:
	scripts/build_deps.sh

tools: $(TOOLS)

bin/kemtool-%: kat/kemtool.c $(HDRS)
	@mkdir -p bin
	$(CC) $(CFLAGS) -DBUILD_TIER='"$*"' -I$(OQS)/include $< -o $@ $(OQS_LINK)

bin/bench_kem-%: bench/bench_kem.c $(HDRS)
	@mkdir -p bin
	$(CC) $(CFLAGS) -DBUILD_TIER='"$*"' -I$(OQS)/include $< -o $@ $(OQS_LINK)

bin/bench_ossl: bench/bench_ossl.c $(HDRS)
	@mkdir -p bin
	$(CC) $(CFLAGS) -I$(OSSL)/include $< -o $@ $(OSSL_LINK)

bin/hs_client: tls/hs_client.c $(HDRS)
	@mkdir -p bin
	$(CC) $(CFLAGS) -I$(OSSL)/include $< -o $@ -L$(OSSL)/lib -Wl,-rpath,$(OSSL)/lib -lssl -lcrypto

bin/dudect_kem-%: ct/dudect_kem.c ct/dudect_run.h ct/dudect/dudect.h $(HDRS)
	@mkdir -p bin
	$(CC) $(CFLAGS) -DBUILD_TIER='"$*"' -I$(OQS)/include $< -o $@ $(OQS_LINK) -lm

bin/dudect_planted: ct/dudect_planted.c ct/dudect_run.h ct/dudect/dudect.h $(HDRS)
	@mkdir -p bin
	$(CC) $(CFLAGS) $< -o $@ -lm

kyber:
	ct/build_kyber.sh

kat: tools
	kat/run_e4.py

bench: tools
	bench/run_e1.py

tls: tools
	tls/run_e2.py

ct: tools kyber
	ct/run_e3.py

figures:
	analysis/make_figures.py

report: figures
	cd report && latexmk -pdf -interaction=nonstopmode -quiet main.tex

all: kat bench tls ct figures

quick:
	$(MAKE) kat bench tls ct QUICK=1
	INCLUDE_QUICK=1 analysis/make_figures.py

demo: tools kyber
	demo/demo.sh

sysinfo:
	@scripts/sysinfo.sh

clean:
	rm -rf bin

distclean: clean
	rm -rf $(BUILD_DIR)
