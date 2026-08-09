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

test: build
	@command -v shellspec >/dev/null 2>&1 || { echo "shellspec not found. install from: https://shellspec.info"; exit 1; }
	shellspec

test-verbose: build
	@command -v shellspec >/dev/null 2>&1 || { echo "shellspec not found. install from: https://shellspec.info"; exit 1; }
	shellspec --format documentation

# ---- standard feats (python-replacement tier) ----
# Compiles feats/<name>/main.zig and stages bin + feat.toml into the registry.
ZISH_FEAT_DIR ?= $(HOME)/.zish/feats/standard
FEAT_NAMES := cnt pk frq snf jls calc

.PHONY: feats
feats:
	@mkdir -p $(ZISH_FEAT_DIR)
	@for f in $(FEAT_NAMES); do \
		mkdir -p $(ZISH_FEAT_DIR)/$$f/bin; \
		zig build-exe -O ReleaseFast -fstrip feats/$$f/main.zig -femit-bin=$(ZISH_FEAT_DIR)/$$f/bin/$$f >/dev/null 2>&1; \
		cp -f feats/$$f/feat.toml $(ZISH_FEAT_DIR)/$$f/feat.toml; \
		echo "staged feat: $$f"; \
	done
