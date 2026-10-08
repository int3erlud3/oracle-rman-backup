# Security Policy

## Reporting a vulnerability

Please do **not** open a public issue for security problems. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository
instead. You can expect an initial response within 7 days.

## Security review notes

- No credentials are accepted, generated or stored: OS authentication for the target,
  wallet alias for an optional recovery catalog.
- The RMAN script is built only from validated values and passed through a private
  temporary command file (`umask 077`), removed on exit.
- Refuses to run as root; destructive RMAN commands (`DELETE ...`, `DELETE INPUT`) are
  only generated when explicitly requested.
- CI runs ShellCheck, the bats suite and a gitleaks secret scan on every push and pull
  request; GitHub Actions are pinned to commit SHAs and run with `contents: read` only.
