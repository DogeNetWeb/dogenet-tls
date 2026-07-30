# pepenet-tls — DANE-enforcing local TLS proxy for .doge/.pepe (see DESIGN.md).
#
# Slice 1: the name-constrained root CA + trust install + the NameConstraints
# accept/reject proof (`make test`).
#
# Links Homebrew openssl@3 EXPLICITLY, never the system default: macOS ships
# LibreSSL, which lacks both the DANE API the proxy will need and EVP_EC_gen.
# Override OPENSSL= if it lives elsewhere (e.g. /usr/local/opt/openssl@3).

OPENSSL ?= /opt/homebrew/opt/openssl@3

# The resolver (slice 4) reuses pepenet-dns's record store + ownership oracle,
# exactly as dnsd links them. DNS := the sibling repo; the rest mirror its Makefile.
DNS     ?= ../pepenet-dns
IDX     := $(DNS)/../namespace-indexer
NET     := $(DNS)/../pepenet-mesh
SECPLIB := $(IDX)/build/secp/lib/libsecp256k1.a
NETLIB  := $(NET)/libpepenetnet.a

CC      ?= cc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -I$(OPENSSL)/include
LDFLAGS ?= -L$(OPENSSL)/lib -Wl,-rpath,$(OPENSSL)/lib -lssl -lcrypto

# include paths to reuse the DNS record store + oracle
DNSINC  := -I$(DNS)/src -I$(NET)/include
# the reused sources + libs behind the real resolver (sp_state rides NETLIB)
DNSSRC  := $(DNS)/src/dns_state.c $(DNS)/src/dns_chain.c $(DNS)/src/zone.c \
           $(DNS)/src/dns_wire.c
DNSLIBS := $(NETLIB) $(SECPLIB) -lsqlite3

all: pepenet-tls ca_test dane_test proxy_test origin_test sscert_test

# the full binary: CLI + CA + trust + proxy + live resolver (reuses the DNS
# record store + ownership oracle, exactly as dnsd links them).
pepenet-tls: src/main.c src/ca.c src/trust.c src/proxy.c src/dane.c src/resolve.c src/origin.c src/sscert.c $(DNSSRC) $(NETLIB)
	$(CC) $(CFLAGS) -Isrc $(DNSINC) -o $@ src/main.c src/ca.c src/trust.c src/proxy.c \
	    src/dane.c src/resolve.c src/origin.c src/sscert.c $(DNSSRC) $(LDFLAGS) $(DNSLIBS) -lpthread

$(NETLIB):
	$(MAKE) -C $(NET)

ca_test: test/ca_test.c src/ca.c
	$(CC) $(CFLAGS) -Isrc -o $@ $^ $(LDFLAGS)

dane_test: test/dane_test.c src/dane.c
	$(CC) $(CFLAGS) -Isrc -o $@ $^ $(LDFLAGS) -lpthread

proxy_test: test/proxy_test.c src/proxy.c src/ca.c src/dane.c
	$(CC) $(CFLAGS) -Isrc -o $@ $^ $(LDFLAGS) -lpthread

# origin_test proves the resolver's PURE core (name split + A/TLSA extraction).
# origin.c only reads the zone struct, so it needs the DNS headers but none of
# the carrier/store link surface — hermetic + fast.
origin_test: test/origin_test.c src/origin.c
	$(CC) $(CFLAGS) -Isrc $(DNSINC) -o $@ $^ $(LDFLAGS)

# sscert_test needs dane.c only for dane_spki_sha256 — the point is that the
# generated pin and the proxy's matcher share one hash function.
sscert_test: test/sscert_test.c src/sscert.c src/dane.c
	$(CC) $(CFLAGS) -Isrc -o $@ $^ $(LDFLAGS) -lpthread

test: ca_test dane_test proxy_test origin_test sscert_test
	./ca_test
	@echo
	./dane_test
	@echo
	./proxy_test
	@echo
	./origin_test
	@echo
	./sscert_test

clean:
	rm -f pepenet-tls ca_test dane_test proxy_test origin_test sscert_test ca_deep_test

.PHONY: all test clean

# ── deeper suites (slice-by-slice hardening; `all`/`test` above are unchanged) ──
# These are separate targets on purpose: several of them currently FAIL against
# real product defects (see the /* FAILS: */ notes in each file), so folding
# them into `test` would make the existing green suite red for reasons that are
# not regressions. Run them explicitly.

dane_deep_test: test/dane_deep_test.c src/dane.c
	$(CC) $(CFLAGS) -Isrc -o $@ $^ $(LDFLAGS) -lpthread

# ca_deep_test covers src/ca.c beyond ca_test's NameConstraints proof: the TLD
# whitelist, path/CN derivation, the SAN-injection guard, cert shape, serial
# entropy and on-disk persistence. Hermetic (its own mkdtemp'd dir), so it
# needs nothing but ca.c and libcrypto.
ca_deep_test: test/ca_deep_test.c src/ca.c
	$(CC) $(CFLAGS) -Isrc -o $@ $^ $(LDFLAGS)

fetch_test: test/fetch_test.c src/fetch.c
	$(CC) $(CFLAGS) -Isrc -o $@ $^ $(LDFLAGS) -lpthread

# resolve_test builds a throwaway indexer db + record store, so it needs the
# same DNS/mesh link surface the real resolver uses.
resolve_test: test/resolve_test.c src/resolve.c src/origin.c $(DNSSRC) $(NETLIB)
	$(CC) $(CFLAGS) -Isrc $(DNSINC) -o $@ test/resolve_test.c src/resolve.c \
	    src/origin.c $(DNSSRC) $(LDFLAGS) $(DNSLIBS) -lpthread

proxy_jitter_test: test/proxy_jitter_test.c src/proxy.c src/ca.c src/dane.c
	$(CC) $(CFLAGS) -Isrc -o $@ $^ $(LDFLAGS) -lpthread

# the four hermetic deep suites
# runs all four even when one fails, then reports the overall verdict --
# several of these suites fail against real defects, and stopping at the first
# would hide the others.
check-deep: dane_deep_test fetch_test resolve_test ca_deep_test
	@rc=0; for t in dane_deep_test fetch_test resolve_test ca_deep_test; do \
	    echo "── $$t ──"; ./$$t || rc=1; echo; \
	done; \
	if [ $$rc -eq 0 ]; then echo "check-deep: all suites passed"; \
	else echo "check-deep: at least one suite FAILED (see the FAILS: notes)"; fi; \
	exit $$rc

# the concurrency/abuse suite (~30 s). PEPENET_JITTER_SEED=<n> replays a run.
check-jitter: proxy_jitter_test
	./proxy_jitter_test

# ThreadSanitizer build of the jitter suite. -O1 -g so TSan reports carry
# usable frames; separate binary so the normal one stays optimized.
proxy_jitter_tsan: test/proxy_jitter_test.c src/proxy.c src/ca.c src/dane.c
	$(CC) -std=c11 -g -O1 -fsanitize=thread -Wall -Wextra -I$(OPENSSL)/include \
	    -Isrc -o $@ $^ $(LDFLAGS) -lpthread

check-jitter-tsan: proxy_jitter_tsan
	TSAN_OPTIONS="halt_on_error=0 second_deadlock_stack=1 history_size=7" ./proxy_jitter_tsan

clean-deep:
	rm -f dane_deep_test fetch_test resolve_test ca_deep_test proxy_jitter_test proxy_jitter_tsan

.PHONY: check-deep check-jitter check-jitter-tsan clean-deep
