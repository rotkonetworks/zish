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
	./tests/aurev_test.sh

test-pty: build
	python3 tests/pty_test.py

# ---- standard feats (python-replacement tier) ----
# Compiles feats/<name>/main.zig and stages bin + feat.toml into the registry.
ZISH_FEAT_DIR ?= $(HOME)/.zish/feats/standard
FEAT_NAMES := cnt pk frq snf jls calc para agent gf aurev
# Feats needing libc (para uses execvp for PATH+env resolution).
FEAT_LIBC := para agent gf aurev

.PHONY: feats
feats:
	@mkdir -p $(ZISH_FEAT_DIR)
	@for f in $(FEAT_NAMES); do \
		mkdir -p $(ZISH_FEAT_DIR)/$$f/bin; \
		lc=""; case " $(FEAT_LIBC) " in *" $$f "*) lc="-lc";; esac; \
		zig build-exe -O ReleaseFast -fstrip $$lc feats/$$f/main.zig -femit-bin=$(ZISH_FEAT_DIR)/$$f/bin/$$f >/dev/null 2>&1; \
		cp -f feats/$$f/feat.toml $(ZISH_FEAT_DIR)/$$f/feat.toml; \
		echo "staged feat: $$f"; \
	done
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
