PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
RELEASE = -Doptimize=ReleaseSafe
SUDO ?= $(if $(filter root,$(shell id -un)),,sudo)

.PHONY: all xemonitor gui bridge test install only-install install-gui install-bridge uninstall clean help

all: xemonitor gui bridge

xemonitor:
	zig build $(RELEASE)

gui:
	zig build gui $(RELEASE)

bridge:
	zig build bridge $(RELEASE)

test:
	zig build test

# make install — reconstrói ReleaseSafe e então instala os 3 binários.
# O build roda como usuário (zig-out/cache nao viram root); só a cópia usa sudo.
install: all
	$(MAKE) only-install

# make only-install — instala o que já está em zig-out/bin, sem rebuild.
only-install:
	$(SUDO) install -Dm 0755 zig-out/bin/xemonitor     $(BINDIR)/xemonitor
	$(SUDO) install -Dm 0755 zig-out/bin/bridge        $(BINDIR)/xemonitor-bridge
	$(SUDO) install -Dm 0755 zig-out/bin/xemonitor-gui $(BINDIR)/xemonitor-gui
	@echo "OK: $(BINDIR)/{xemonitor, xemonitor-bridge, xemonitor-gui}"

install-gui: gui
	$(SUDO) install -Dm 0755 zig-out/bin/xemonitor-gui $(BINDIR)/xemonitor-gui

install-bridge: bridge
	$(SUDO) install -Dm 0755 zig-out/bin/bridge $(BINDIR)/xemonitor-bridge

uninstall:
	$(SUDO) rm -f $(BINDIR)/xemonitor $(BINDIR)/xemonitor-bridge $(BINDIR)/xemonitor-gui

clean:
	rm -rf zig-out .zig-cache

help:
	@printf 'make all | xemonitor | gui | bridge | test\n'
	@printf 'make install      = build ReleaseSafe + instala os 3 binarios\n'
	@printf 'make only-install = so copia o que ja esta em zig-out/bin\n'
	@printf 'make install-gui | install-bridge | uninstall | clean\n'