#!/usr/bin/env bash
#
# atomic/mayhem/test.sh — RUN uber-go/atomic's OWN Go test suite (`go test ./...`) and emit
# a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: atomic's suite is a REAL behavioural suite — string_test.go/bool_test.go/
# int32_test.go/etc drive dozens of typed cases via stretchr/testify `require`/`assert` and check
# exact Load()/String()/CompareAndSwap() results, JSON/text marshal round trips, and concurrent
# CAS semantics. It asserts BEHAVIOUR, not "exits 0", so a no-op / stub patch that breaks an
# atomic wrapper's Load/Store/CAS FAILS this oracle.
#
# This runs the project's own normal-flags suite (no sanitizer/fuzz build). build.sh copies the
# fuzz harness to the repo root (fuzz_test.go) and writes a register.go shim, also at the repo
# root; both are ordinary, compilable Go (register.go is a blank import; fuzz_test.go imports the
# stdlib testing pkg), so `go test ./...` still compiles and runs the full suite unchanged. The
# harness source lives at mayhem/fuzz_test.go.src (a non-.go name) so `go test ./...` never tries
# to compile it directly; build.sh copies it to ./fuzz_test.go (package atomic, repo root, where
# `String` is in scope) before this runs.
#
# Anti-reward-hacking behavioral probe (§6.3): after running go test (statically linked, immune to
# LD_PRELOAD sabotage), this script also executes /mayhem/FuzzTest (dynamically linked via
# clang+ASan) against a known seed and asserts that libFuzzer emits "Executed". The LD_PRELOAD
# sabotage neuters FuzzTest (not in /usr/bin etc.), causing it to exit silently → grep fails →
# FAILED increments → the oracle is NOT reward-hackable.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:/root/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

echo "=== running: go test -json ./... ==="
# -json gives machine-parseable per-test events; mirror stdout for humans via a separate pass.
JSON="$SRC/mayhem-build/gotest.json"
mkdir -p "$SRC/mayhem-build"
go test -json ./... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Show package-level summary + any build/test errors for humans.
go test ./... 2>&1 | tail -40 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines that carry a non-empty "Test" field). Subtests included — they are
# real asserted cases. Package-level pass/fail lines have no "Test" field and are excluded.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported a non-zero exit but we counted 0 failures (e.g. a
# package build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked FuzzTest binary (anti-reward-hacking, §6.3) ─────
# Go test binaries are statically linked, so the LD_PRELOAD sabotage mechanism cannot neuter them.
# /mayhem/FuzzTest IS dynamically linked (built with clang+ASan). Run it single-shot against a
# known seed and assert that libFuzzer emits "Executed" — proving it actually processed the input.
# The sabotage LD_PRELOAD neuters FuzzTest (not in /usr/bin etc.), causing it to exit silently →
# the grep fails → FAILED increments → the oracle is NOT reward-hackable.
PROBE_INPUT="$SRC/mayhem/testsuite/fuzz_test/seed_basic"
if [ -x /mayhem/FuzzTest ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: FuzzTest single-shot on known seed ==="
  PROBE_OUT=$(/mayhem/FuzzTest "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: FuzzTest executed the seed input (String marshal/CAS engine active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: FuzzTest produced no 'Executed' output (engine inactive or sabotaged)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
