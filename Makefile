SHELL_FILES := bin/oracle-rman-backup tests/mocks/rman tests/oracle-rman-backup.bats
GITLEAKS_IMAGE := ghcr.io/gitleaks/gitleaks:v8.30.1
PREFIX ?= /usr/local

.PHONY: all lint test scan install
all: lint test

lint:
	shellcheck -x -S style $(SHELL_FILES)
	shellcheck -x -S style -o check-unassigned-uppercase,require-double-brackets bin/oracle-rman-backup

test:
	bats tests

scan:
	docker run --rm -v "$(CURDIR):/repo:ro" $(GITLEAKS_IMAGE) git /repo --redact --no-banner

install:
	install -D -m 0755 bin/oracle-rman-backup $(DESTDIR)$(PREFIX)/bin/oracle-rman-backup
