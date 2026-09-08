PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man/man1
SHELL_PATH = $(BINDIR)/zish

.PHONY: all build install uninstall add-shell remove-shell clean test test-verbose

all: build

build:
	zig build --release=safe

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
test: build
	./tests/regress.sh
	zig build test
	zig test feats/agent/main.zig
	zig test -lc feats/gf/main.zig
	./tests/gf_test.sh
	./tests/aur_test.sh
	./tests/budget_test.sh
	./tests/verify_test.sh
	./tests/ask_test.sh
	./tests/team_test.sh
	./benchmark/run.sh --selftest

test-pty: build
	python3 tests/pty_test.py

# ---- standard feats (python-replacement tier) ----
# Compiles feats/<name>/main.zig and stages bin + feat.toml into the registry.
ZISH_FEAT_DIR ?= $(HOME)/.zish/feats/standard
FEAT_NAMES := cnt pk frq snf jls calc para agent gf aur budget verify ask team web
# Feats needing libc (para uses execvp for PATH+env resolution).
FEAT_LIBC := para agent gf aur budget verify ask team web

.PHONY: feats
feats:
	@mkdir -p $(ZISH_FEAT_DIR)
	@failed=""; \
	for f in $(FEAT_NAMES); do \
		mkdir -p $(ZISH_FEAT_DIR)/$$f/bin; \
		lc=""; case " $(FEAT_LIBC) " in *" $$f "*) lc="-lc";; esac; \
		if ! zig build-exe -O ReleaseFast -fstrip $$lc feats/$$f/main.zig -femit-bin=$(ZISH_FEAT_DIR)/$$f/bin/$$f; then \
			echo "FEAT BUILD FAILED: $$f (not staged)" >&2; failed="$$failed $$f"; continue; \
		fi; \
		cp -f feats/$$f/feat.toml $(ZISH_FEAT_DIR)/$$f/feat.toml; \
		echo "staged feat: $$f"; \
	done; \
	if [ -n "$$failed" ]; then echo "FEATS FAILED TO BUILD:$$failed" >&2; exit 1; fi
	@mkdir -p $(HOME)/.zish/rubrics
	@cp -f rubrics/*.toml $(HOME)/.zish/rubrics/ 2>/dev/null && \
		echo "staged rubrics" || true

# ---- feat distribution ----
# Pack one feat as the tarball gf installs (feat.toml + bin/<name> at top
# level). This is how the agent ships while its source stays in this repo:
# the artifact is attached to releases; users run `gf <url>`.
.PHONY: dist-agent
dist-agent:
	@mkdir -p dist/.pkg-agent/bin
	@zig build-exe -O ReleaseFast -fstrip -lc feats/agent/main.zig \
		-femit-bin=dist/.pkg-agent/bin/agent >/dev/null 2>&1
	@cp -f feats/agent/feat.toml dist/.pkg-agent/feat.toml
	@v=$$(sed -n 's/^version = "\(.*\)"/\1/p' feats/agent/feat.toml); \
		tar -czf dist/agent-$${v:-0.0.0}.tar.gz -C dist/.pkg-agent feat.toml bin; \
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
	@for f in $(FEAT_NAMES); do \
		v=$$(sed -n 's/^version = "\(.*\)"/\1/p' feats/$$f/feat.toml); v=$${v:-0.0.0}; \
		help=$$(sed -n 's/^help = "\(.*\)"/\1/p' feats/$$f/feat.toml | tr -d '"\\'); \
		lc=""; case " $(FEAT_LIBC) " in *" $$f "*) lc="-lc";; esac; \
		for a in $(DIST_ARCHES); do \
			pkg=dist/.pkg-$$f-$$a; mkdir -p $$pkg/bin; \
			if ! zig build-exe -O ReleaseFast -fstrip $$lc -target $$a-linux-musl \
				feats/$$f/main.zig -femit-bin=$$pkg/bin/$$f 2>/dev/null; then \
				echo "dist: SKIP $$f/$$a (musl build failed)" >&2; rm -rf $$pkg; continue; \
			fi; \
			cp -f feats/$$f/feat.toml $$pkg/feat.toml; \
			file=$$f-$$v-$$a-linux-musl.tar.gz; \
			tar -czf dist/$$file -C $$pkg feat.toml bin; rm -rf $$pkg; \
			sha=$$(sha256sum dist/$$file | cut -d' ' -f1); \
			printf '{"name":"%s","version":"%s","arch":"%s","tier":"standard","url":"%s/%s","sha256":"%s","desc":"%s"}\n' \
				"$$f" "$$v" "$$a" "$(REL_BASE)" "$$file" "$$sha" "$$help" >> dist/index.jsonl; \
			echo "dist: $$file"; \
		done; \
	done
	@echo "wrote dist/index.jsonl ($$(grep -c . dist/index.jsonl) entries) → publish with:"
	@echo "  gh release create $(REL_TAG) dist/*.tar.gz dist/index.jsonl --repo $(REL_REPO)"
