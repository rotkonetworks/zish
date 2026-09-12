PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man/man1
SHELL_PATH = $(BINDIR)/zish

.PHONY: all build install uninstall add-shell remove-shell clean test test-verbose

all: build

build:
	zig build --release=safe

# Every feat built and installed into zig-out. What the suites exec, so they
# test the binaries this build system produced rather than compiling their own:
# they each used to pass their own `-lc`, which is how they came to validate a
# differently linked binary than any install ships.
build-all:
	zig build --release=safe -Dfeats=all

install: build feats
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(MANDIR)
	install -m 755 zig-out/bin/zish $(DESTDIR)$(SHELL_PATH)
	install -m 644 zish.1 $(DESTDIR)$(MANDIR)/zish.1
	@echo "installed zish to $(SHELL_PATH)"
	@echo "installed man page to $(MANDIR)/zish.1"
	@echo "run 'sudo make add-shell' to add to /etc/shells"

add-shell:
	@if ! grep -q "^$(SHELL_PATH)$$" /etc/shells; then \
		echo "$(SHELL_PATH)" >> /etc/shells; \
		echo "added $(SHELL_PATH) to /etc/shells"; \
	else \
		echo "$(SHELL_PATH) already in /etc/shells"; \
	fi

remove-shell:
	@if grep -q "^$(SHELL_PATH)$$" /etc/shells; then \
		sed -i "\|^$(SHELL_PATH)$$|d" /etc/shells; \
		echo "removed $(SHELL_PATH) from /etc/shells"; \
	else \
		echo "$(SHELL_PATH) not in /etc/shells"; \
	fi

uninstall: remove-shell
	rm -f $(DESTDIR)$(SHELL_PATH)
	rm -f $(DESTDIR)$(MANDIR)/zish.1
	@echo "uninstalled zish"

clean:
	rm -rf zig-out .zig-cache

# The regression suite (differential against bash) + unit tests are the
# canonical test surface, and the same thing CI runs. The interactive pty
# suite needs a tty and python, so it is opt-in via `make test-pty`.
#
# `make test` builds every feat first (`build-all`) and the suites exec those
# artefacts; the feats' own unit tests run inside `zig build test`, so there is
# no per-suite compile and no per-suite link decision to drift.
test: build-all
	./tests/regress.sh
	zig build test -Dfeats=all
	./tests/agent_test.sh
	./tests/gf_test.sh
	./tests/aur_test.sh
	./tests/budget_test.sh
	./tests/verify_test.sh
	./tests/ask_test.sh
	./tests/team_test.sh
	./tests/bus_test.sh
	./tests/web_test.sh
	./tests/feat_leaks_test.sh
	./benchmark/run.sh --selftest

test-pty: build
	python3 tests/pty_test.py

# ---- standard feats (python-replacement tier) ----
# Staging into the local registry is now build.zig's job, because build.zig owns
# which feats exist, which of them link libc, and where they install. This
# target only names the local-dev placement: the registry layout a feat resolver
# reads is <root>/standard/<name>/{bin,feat.toml}, and
# `-Dfeat-layout=registry --prefix <root>` produces exactly that.
#
# The shell loop that used to live here compiled feats itself with its own
# copies of FEAT_NAMES and FEAT_LIBC, and both had drifted from build.zig: this
# one shipped `bus` that build.zig omitted, and it said only `para` needs libc
# while build.zig still linked nine.
ZISH_FEAT_ROOT ?= $(HOME)/.zish/feats

.PHONY: feats
feats:
	zig build install-feats --release=safe -Dfeats=all -Dfeat-layout=registry --prefix $(ZISH_FEAT_ROOT)

# ---- feat distribution ----
# Pack one feat as the tarball gf installs (feat.toml + bin/<name> at top
# level). This is how the agent ships while its source stays in this repo:
# the artifact is attached to releases; users run `gf <url>`.
#
# The compile is a build.zig step with that one feat named, so the packaging
# step builds exactly what it packs instead of the whole set.
.PHONY: dist-agent
dist-agent:
	@rm -rf dist/.pkg-agent
	@zig build install-feats --release=safe -Dfeats=agent -Dfeat-layout=registry --prefix dist/.pkg-agent
	@v=$$(sed -n 's/^version = "\(.*\)"/\1/p' feats/agent/feat.toml); \
		tar -czf dist/agent-$${v:-0.0.0}.tar.gz -C dist/.pkg-agent/standard/agent feat.toml bin; \
		rm -rf dist/.pkg-agent; \
		echo "dist/agent-$${v:-0.0.0}.tar.gz"

# ---- the whole feat catalog: `make dist-all` ------------------------------
# Cross-compiles EVERY feat to static musl for each DIST_ARCH and packs it as
# the tarball `gf install` fetches (feat.toml + bin/<name> at top level), then
# emits dist/index.jsonl — the crates.io-for-feats index gf resolves by name.
#
# URL discipline (matters for smoothness): the index is published at the ROLLING
# releases/latest/download/index.jsonl, but every ENTRY pins an IMMUTABLE
# releases/download/<tag>/<file> tarball URL + sha256, so a release cut between a
# user's index fetch and tarball fetch can never 404 a pinned artifact.
# Static musl means no host-glibc symbol pinning and no "Exec format error" on
# another arch — the `arch` field + gf's host-arch filter hand out the right one.
# Entries are tier "standard": gf trusts its OWN default index (rotko's release
# channel) enough to install callable, and quarantines everything else.
REL_REPO ?= rotkonetworks/zish
REL_TAG  ?= $(shell git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)
REL_BASE  = https://github.com/$(REL_REPO)/releases/download/$(REL_TAG)
DIST_ARCHES ?= x86_64 aarch64

.PHONY: dist-all
dist-all:
	@rm -rf dist && mkdir -p dist
	@: > dist/index.jsonl
	@for a in $(DIST_ARCHES); do \
		stage=dist/.musl-$$a; \
		echo "dist: building all feats for $$a-linux-musl"; \
		if ! zig build install-feats --release=safe -Dfeats=all -Dfeat-layout=registry \
			-Dtarget=$$a-linux-musl --prefix $$stage; then \
			echo "dist: SKIP arch $$a (musl build failed)" >&2; rm -rf $$stage; continue; \
		fi; \
		for d in $$stage/standard/*/; do \
			f=$$(basename $$d); \
			v=$$(sed -n 's/^version = "\(.*\)"/\1/p' $$d/feat.toml); v=$${v:-0.0.0}; \
			help=$$(sed -n 's/^help = "\(.*\)"/\1/p' $$d/feat.toml | tr -d '"\\'); \
			file=$$f-$$v-$$a-linux-musl.tar.gz; \
			tar -czf dist/$$file -C $$d feat.toml bin; \
			sha=$$(sha256sum dist/$$file | cut -d' ' -f1); \
			printf '{"name":"%s","version":"%s","arch":"%s","tier":"standard","url":"%s/%s","sha256":"%s","desc":"%s"}\n' \
				"$$f" "$$v" "$$a" "$(REL_BASE)" "$$file" "$$sha" "$$help" >> dist/index.jsonl; \
			echo "dist: $$file"; \
		done; \
		rm -rf $$stage; \
	done
	@echo "wrote dist/index.jsonl ($$(grep -c . dist/index.jsonl) entries) → publish with:"
	@echo "  gh release create $(REL_TAG) dist/*.tar.gz dist/index.jsonl --repo $(REL_REPO)"
