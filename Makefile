BIN    := fileanchor
BINDIR ?= $(HOME)/bin
PREFIX ?= /usr/local

# SwiftPM writes to .build/<triple>/<config>/ — neither stable nor
# unambiguous: debug and release both exist, and installing the wrong one is
# invisible. `build` bridges that to repo/<name>, the one path everything
# else names.

.PHONY: build install uninstall link unlink test clean

build:
	swift build -c release
	@install -m 755 .build/release/$(BIN) ./$(BIN)

# Link once, then never again: rebuilding is deploying. A stale copy fails silently,
# a dangling link fails at the next call.
link: build
	@install -d $(BINDIR)
	@ln -sfn $(CURDIR)/$(BIN) $(BINDIR)/$(BIN)
	@echo "linked $(BINDIR)/$(BIN) -> $(CURDIR)/$(BIN)"

unlink:
	rm -f $(BINDIR)/$(BIN)

# Selftest executable, not a test target: command-line Swift without XCTest
# reports a missing test target as success.
test:
	swift build -c release --product fileanchor-selftest
	.build/release/fileanchor-selftest

# Published repo: `install` copies into $(PREFIX)/bin for anyone who clones
# this. A clone is not a stable place to point a symlink at — the symlink
# form is `make link`, for the machine this is developed on.
install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)

uninstall:
	rm -f $(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN)
	swift package clean
