#!/usr/bin/env bats
# Tests for bin/oracle-rman-backup using a mocked rman binary (tests/mocks/rman).

setup() {
  ORB="$BATS_TEST_DIRNAME/../bin/oracle-rman-backup"
  OH="$BATS_TEST_TMPDIR/oracle_home"
  mkdir -p "$OH/bin"
  cp "$BATS_TEST_DIRNAME/mocks/rman" "$OH/bin/rman"
  export MOCK_RMAN_RECORD="$BATS_TEST_TMPDIR/record"
  mkdir -p "$MOCK_RMAN_RECORD"
  export LOGS="$BATS_TEST_TMPDIR/logs"
  export ORACLE_HOME="$OH" ORACLE_SID=FREE
  unset ORACLE_BASE NO_BANNER MOCK_RMAN_OUTPUT MOCK_RMAN_EXIT
  FIX="$BATS_TEST_DIRNAME/fixtures"
}

orb() { run "$ORB" "$@" --log-dir "$LOGS"; }

cmdfile() { cat "$MOCK_RMAN_RECORD/cmdfile"; }

# ---- dry-run / script generation ---------------------------------------------
@test "dry-run prints the RMAN script and does not run rman" {
  run "$ORB" full --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONNECT TARGET /"* ]]
  [[ "$output" == *"BACKUP INCREMENTAL LEVEL 0 DATABASE TAG 'FULL_"* ]]
  [[ "$output" == *"BACKUP CURRENT CONTROLFILE"* ]]
  [[ "$output" == *"BACKUP SPFILE"* ]]
  [ ! -e "$MOCK_RMAN_RECORD/args" ]
  [ ! -e "$LOGS" ]
}

@test "full backup with channels, compression, section size and destination" {
  run "$ORB" full --dry-run --channels 3 --compress --section-size 32G --dest /u02/backup/FREE/ --tag NIGHTLY
  [ "$status" -eq 0 ]
  [ "$(grep -c "ALLOCATE CHANNEL d[0-9] DEVICE TYPE DISK FORMAT '/u02/backup/FREE/%d_%T_%U';" <<<"$output")" -eq 3 ]
  [[ "$output" == *"BACKUP AS COMPRESSED BACKUPSET INCREMENTAL LEVEL 0 SECTION SIZE 32G DATABASE TAG 'NIGHTLY';"* ]]
  [[ "$output" == *"ARCHIVELOG ALL NOT BACKED UP 1 TIMES TAG 'NIGHTLY_ARC';"* ]]
}

@test "incremental level 1, differential and cumulative" {
  run "$ORB" incr --dry-run
  [[ "$output" == *"INCREMENTAL LEVEL 1 DATABASE"* ]]
  run "$ORB" incr --dry-run --cumulative
  [[ "$output" == *"INCREMENTAL LEVEL 1 CUMULATIVE DATABASE"* ]]
}

@test "archivelog backup keeps input unless --delete-input" {
  run "$ORB" arch --dry-run
  [[ "$output" == *"NOT BACKED UP 1 TIMES TAG 'ARCH_"* ]]
  [[ "$output" != *"DELETE INPUT"* ]]
  run "$ORB" arch --dry-run --delete-input
  [[ "$output" == *"_ARC' DELETE INPUT;"* ]]
}

@test "validate, restore-check and preview scripts" {
  run "$ORB" validate --dry-run
  [[ "$output" == *"BACKUP VALIDATE CHECK LOGICAL DATABASE ARCHIVELOG ALL;"* ]]
  run "$ORB" restore-check --dry-run
  [[ "$output" == *"RESTORE DATABASE VALIDATE CHECK LOGICAL;"* ]]
  [[ "$output" == *"RESTORE CONTROLFILE VALIDATE;"* ]]
  run "$ORB" preview --dry-run
  [[ "$output" == *"RESTORE DATABASE PREVIEW SUMMARY;"* ]]
}

@test "maintenance only reports unless --delete is given" {
  run "$ORB" maintenance --dry-run
  [[ "$output" == *"CROSSCHECK BACKUP;"* ]]
  [[ "$output" == *"REPORT OBSOLETE RECOVERY WINDOW OF 7 DAYS;"* ]]
  [[ "$output" != *"DELETE"* ]]
  run "$ORB" maintenance --dry-run --delete --retention-days 14
  [[ "$output" == *"DELETE NOPROMPT EXPIRED BACKUP;"* ]]
  [[ "$output" == *"DELETE NOPROMPT OBSOLETE RECOVERY WINDOW OF 14 DAYS;"* ]]
  run "$ORB" maintenance --dry-run --delete --redundancy 2
  [[ "$output" == *"DELETE NOPROMPT OBSOLETE REDUNDANCY 2;"* ]]
}

@test "recovery catalog uses a wallet alias, never a password" {
  run "$ORB" full --dry-run --catalog-alias rcat_prod
  [[ "$output" == *"CONNECT CATALOG /@rcat_prod"* ]]
  run "$ORB" --help
  [[ "$output" != *"--password"* ]]
}

# ---- input validation ----------------------------------------------------------
@test "invalid input is rejected with exit 3 (UNKNOWN)" {
  local bad
  for bad in "--channels 0" "--channels 17" "--channels x" "--section-size 32T" "--tag a;b" \
    "--tag ABCDEFGHIJKLMNOPQRSTUVWXYZ1" "--dest relative/path" "--dest /tmp/x'y" "--dest /u02/../etc" \
    "--retention-days 0" "--catalog-alias a@b" "--format xml" "--cumulative" "--delete" "--sid 1abc"; do
    # shellcheck disable=SC2086
    run "$ORB" full --dry-run $bad
    [ "$status" -eq 3 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "missing action, unknown option and conflicting retention are usage errors" {
  run "$ORB" --dry-run
  [ "$status" -eq 3 ]
  run "$ORB" full --bogus
  [ "$status" -eq 3 ]
  run "$ORB" maintenance --retention-days 7 --redundancy 2 --dry-run
  [ "$status" -eq 3 ]
  run "$ORB" full incr --dry-run
  [ "$status" -eq 3 ]
}

@test "missing ORACLE_SID or rman binary is UNKNOWN" {
  run env -u ORACLE_SID "$ORB" full --log-dir "$LOGS"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ORACLE_SID"* ]]
  run "$ORB" full --oracle-home "$BATS_TEST_TMPDIR/nohome" --log-dir "$LOGS"
  [ "$status" -eq 3 ]
}

# ---- execution with the mock --------------------------------------------------------
@test "successful backup: OK, exit 0, script via cmdfile, log written" {
  export TWO_TASK=remote_db
  orb full --tag T1
  [ "$status" -eq 0 ]
  [[ "$output" == "OK - full backup of FREE completed in "*"(tag T1), log: $LOGS/"* ]]
  grep -qx 'msgno' "$MOCK_RMAN_RECORD/args"
  grep -q '^cmdfile=' "$MOCK_RMAN_RECORD/args"
  cmdfile | grep -q "DATABASE TAG 'T1';"
  grep -qx 'ORACLE_SID=FREE' "$MOCK_RMAN_RECORD/env"
  grep -qx 'TWO_TASK=' "$MOCK_RMAN_RECORD/env"
  grep -qx 'NLS_DATE_FORMAT=YYYY-MM-DD HH24:MI:SS' "$MOCK_RMAN_RECORD/env"
  log=$(ls "$LOGS"/oracle-rman-backup_FREE_full_*.log)
  grep -q "Recovery Manager complete." "$log"
  grep -q "\[OK\] completed (rman exit 0" "$log"
  [ "$(stat -c %a "$LOGS")" = 700 ]
  [ "$(stat -c %a "$log")" = 600 ]
}

@test "the temporary command file is removed afterwards" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  orb arch
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "RMAN failure is CRITICAL (exit 2) with error codes" {
  MOCK_RMAN_EXIT=1 MOCK_RMAN_OUTPUT="$FIX/rman_error.log" orb full
  [ "$status" -eq 2 ]
  [[ "$output" == CRITICAL* ]]
  [[ "$output" == *"codes: ORA-19502,ORA-27072,RMAN-03009"* ]]
}

@test "error stack with exit 0 is still CRITICAL" {
  MOCK_RMAN_OUTPUT="$FIX/rman_error.log" orb arch
  [ "$status" -eq 2 ]
}

@test "known RMAN warnings give WARNING (exit 1)" {
  MOCK_RMAN_OUTPUT="$FIX/rman_warning.log" orb arch --delete-input
  [ "$status" -eq 1 ]
  [[ "$output" == WARNING* ]]
}

@test "corrupt blocks found by validate are CRITICAL" {
  MOCK_RMAN_OUTPUT="$FIX/validate_corrupt.log" orb validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"corrupt blocks found by VALIDATE"* ]]
}

@test "JSON summary is valid and complete" {
  command -v jq >/dev/null || skip "jq not installed"
  MOCK_RMAN_EXIT=1 MOCK_RMAN_OUTPUT="$FIX/rman_error.log" orb full --format json --tag J1
  [ "$status" -eq 2 ]
  [ "$(jq -r .status <<<"$output")" = CRITICAL ]
  [ "$(jq -r .exit_code <<<"$output")" = 2 ]
  [ "$(jq -r .tag <<<"$output")" = J1 ]
  [ "$(jq -r '.errors | join(",")' <<<"$output")" = "ORA-19502,ORA-27072,RMAN-03009" ]
  [[ "$(jq -r .log_file <<<"$output")" == "$LOGS/"* ]]
}

@test "check-syntax runs rman checksyntax without logging" {
  orb full --check-syntax
  [ "$status" -eq 0 ]
  grep -qx checksyntax "$MOCK_RMAN_RECORD/args"
  [ ! -e "$LOGS" ]
}

@test "a second concurrent run is refused by the lock" {
  command -v flock >/dev/null || skip "flock not installed"
  mkdir -p "$LOGS"
  exec 8>>"$LOGS/.oracle-rman-backup-FREE.lock"
  flock -n 8
  orb arch
  exec 8>&-
  [ "$status" -eq 3 ]
  [[ "$output" == *"holds"* ]]
  [ ! -e "$MOCK_RMAN_RECORD/args" ]
}

@test "--max-runtime: a timed-out rman is CRITICAL" {
  command -v timeout >/dev/null || skip "timeout not installed"
  MOCK_RMAN_EXIT=124 orb arch --max-runtime 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"aborted after --max-runtime 1 min"* ]]
}

@test "old own log files are pruned, other files are kept" {
  mkdir -p "$LOGS"
  touch -d '40 days ago' "$LOGS/oracle-rman-backup_FREE_full_20250101T000000.log" "$LOGS/other.log"
  orb arch
  [ "$status" -eq 0 ]
  [ ! -e "$LOGS/oracle-rman-backup_FREE_full_20250101T000000.log" ]
  [ -e "$LOGS/other.log" ]
}

@test "ORACLE_BASE determines the default log directory" {
  export ORACLE_BASE="$BATS_TEST_TMPDIR/base"
  run "$ORB" preview
  [ "$status" -eq 0 ]
  ls "$ORACLE_BASE/admin/FREE/rman_logs/"oracle-rman-backup_FREE_preview_*.log
}

@test "refuses to run as root" {
  command -v unshare >/dev/null || skip "unshare not available"
  unshare -r true 2>/dev/null || skip "user namespaces not available"
  run unshare -r "$ORB" full --log-dir "$LOGS"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing to run as root"* ]]
}

# ---- banner -----------------------------------------------------------------
# script(1) runs the command on a pseudo-terminal, so stdout/stderr are a TTY.
on_tty() {
  command -v script >/dev/null || skip "script(1) not available"
  run script -qefc "$(printf '%q ' "$@")" /dev/null </dev/null
}

@test "banner is printed on an interactive terminal" {
  on_tty "$ORB" full --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bastion Ops Toolkit"* ]]
  [[ "$output" == *"ORACLE RMAN BACKUP"* ]]
}

@test "banner is not printed when stderr is not a terminal (cron/systemd)" {
  run "$ORB" full --dry-run
  [[ "$output" != *"Bastion Ops Toolkit"* ]]
}

@test "--no-banner and NO_BANNER=1 suppress the banner on a terminal" {
  on_tty "$ORB" full --dry-run --no-banner
  [[ "$output" != *"Bastion Ops Toolkit"* ]]
  on_tty env NO_BANNER=1 "$ORB" full --dry-run
  [[ "$output" != *"Bastion Ops Toolkit"* ]]
  on_tty env NO_BANNER=0 "$ORB" full --dry-run
  [[ "$output" == *"Bastion Ops Toolkit"* ]]
}

@test "JSON output never contains the banner, even on a terminal" {
  on_tty "$ORB" arch --format json --log-dir "$LOGS"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Bastion Ops Toolkit"* ]]
}

@test "--help and --version show the banner on a terminal only" {
  on_tty "$ORB" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bastion Ops Toolkit"* ]]
  run "$ORB" --version
  [ "$output" = "oracle-rman-backup 1.0.0" ]
}

@test "README banner matches the runtime banner" {
  on_tty "$ORB" --version
  # first ```text block of the README
  expected=$(awk -v fence='```' '$0 == fence "text" { on = 1; next } on && $0 == fence { exit } on' "$BATS_TEST_DIRNAME/../README.md")
  actual=$(printf '%s\n' "$output" | tr -d '\r')
  [ -n "$expected" ]
  [[ "$actual" == "$expected"* ]]
}
