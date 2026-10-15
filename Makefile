PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

SCRIPTS = dockersand $(wildcard dockersand-args-*)

.PHONY: install uninstall

install:
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 $(SCRIPTS) "$(DESTDIR)$(BINDIR)"

uninstall:
	cd "$(DESTDIR)$(BINDIR)" && rm -f $(SCRIPTS)
