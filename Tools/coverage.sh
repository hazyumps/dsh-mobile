#!/bin/bash
# Kit line coverage: report it, hold the ratchet, and enforce the must-test floors.
#
#   Tools/coverage.sh                    # check (run after `swift test --enable-code-coverage`)
#   Tools/coverage.sh --update-baseline  # raise Tools/coverage-baseline.txt to today's number
#   Tools/coverage.sh --report           # print the per-file table, check nothing
#
# Why a ratchet and not a fixed floor: a fixed percentage invites filler tests written to hit
# the number. The ratchet only says "do not go backwards", and the must-test list says which
# files are too important to leave thin (docs/process/WORKFLOW.md, "Coverage").
#
# Generated/ is excluded: its decoding is pinned by GeneratedModelTests through the manifest,
# and 7k lines of DTOs would drown the signal from the hand-written kit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASELINE_FILE="Tools/coverage-baseline.txt"
MUST_TEST_FILE="Tools/must-test.txt"
# Allowed run-to-run wobble. Coverage of concurrent code moves a little between runs (a
# cancellation that lands before or after an await covers a different line).
TOLERANCE="0.30"
KIT_PREFIX="$ROOT/Sources/DSHRemoteKit/"
IGNORE='(Tests|Generated|\.build|Smoke)/'

mode="check"
case "${1:-}" in
  --update-baseline) mode="update" ;;
  --report) mode="report" ;;
  "") ;;
  *) echo "usage: $0 [--update-baseline|--report]" >&2; exit 2 ;;
esac

profdata=".build/debug/codecov/default.profdata"
binary=".build/debug/DSHRemoteKitTests.xctest/Contents/MacOS/DSHRemoteKitTests"
if [[ ! -f "$profdata" || ! -f "$binary" ]]; then
  echo "coverage: no profile. Run: swift test --disable-sandbox --enable-code-coverage" >&2
  exit 2
fi

# Columns of `llvm-cov report`: Filename Regions Missed Cover Functions Missed Executed
# Lines Missed Cover Branches Missed Cover. We want Lines (8), Missed (9), Cover (10).
table="$(xcrun llvm-cov report "$binary" -instr-profile "$profdata" \
  -ignore-filename-regex="$IGNORE" 2>/dev/null \
  | awk -v prefix="$KIT_PREFIX" 'NR > 2 && NF >= 10 { f = $1; sub(prefix, "", f); printf "%s %s %s %s\n", f, $8, $9, $10 }')"

total="$(echo "$table" | awk '$1 == "TOTAL" { sub("%", "", $4); print $4 }')"
if [[ -z "$total" ]]; then
  echo "coverage: could not read a TOTAL line from llvm-cov" >&2
  exit 2
fi

if [[ "$mode" == "report" ]]; then
  echo "$table" | awk '{ printf "%-48s %6s lines %6s missed %8s\n", $1, $2, $3, $4 }'
  exit 0
fi

baseline="$(tr -d '[:space:]' < "$BASELINE_FILE")"

if [[ "$mode" == "update" ]]; then
  if awk -v t="$total" -v b="$baseline" 'BEGIN { exit !(t < b) }'; then
    echo "coverage: $total% is below the baseline $baseline%; the baseline only goes up." >&2
    exit 1
  fi
  echo "$total" > "$BASELINE_FILE"
  echo "coverage: baseline $baseline% -> $total%"
  exit 0
fi

status=0

# 1. The ratchet.
if awk -v t="$total" -v b="$baseline" -v tol="$TOLERANCE" 'BEGIN { exit !(t + tol < b) }'; then
  echo "coverage: FAIL kit line coverage $total% is below the baseline $baseline% (tolerance $TOLERANCE)."
  echo "          A test was removed, or new code landed without tests. Tools/coverage.sh --report"
  echo "          shows the per-file table."
  status=1
elif awk -v t="$total" -v b="$baseline" -v tol="$TOLERANCE" 'BEGIN { exit !(t > b + tol) }'; then
  echo "coverage: ok $total% (baseline $baseline%). It rose: lock it in with"
  echo "          Tools/coverage.sh --update-baseline, and commit $BASELINE_FILE."
else
  echo "coverage: ok $total% (baseline $baseline%)"
fi

# 2. Must-test floors. Each line: <path under Sources/DSHRemoteKit> <minimum %> [# why]
while read -r path floor _; do
  [[ -z "$path" || "$path" == \#* ]] && continue
  got="$(echo "$table" | awk -v p="$path" '$1 == p { sub("%", "", $4); print $4 }')"
  if [[ -z "$got" ]]; then
    echo "coverage: FAIL $path is in $MUST_TEST_FILE but has no coverage data (renamed or untested?)"
    status=1
  elif awk -v g="$got" -v f="$floor" 'BEGIN { exit !(g < f) }'; then
    echo "coverage: FAIL $path is at $got%, below its must-test floor of $floor%"
    status=1
  fi
done < "$MUST_TEST_FILE"

exit $status
