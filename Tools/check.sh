#!/bin/bash
# The single definition of "green" for this repo. The pre-push hook runs it; a future CI runner
# should call exactly this script and nothing else, so the laptop and the server cannot disagree.
#
#   Tools/check.sh          # everything (about 3–5 min cold, ~1 min warm)
#   Tools/check.sh --fast   # everything except the two app builds (~30 s)
#   Tools/check.sh --red    # for a planner's "Tests:" commit: the tests must COMPILE and must
#                           # FAIL. A compile error is not red, it is broken (WORKFLOW.md step 3).
#
# Steps, in order of cost: lint, generated-model drift, version consistency, planner-test guard,
# kit tests with coverage, coverage ratchet + must-test floors, app build Debug + Release.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mode="full"
case "${1:-}" in
  --fast) mode="fast" ;;
  --red) mode="red" ;;
  "" | --full) ;;
  -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
  *) echo "usage: $0 [--fast|--red]" >&2; exit 2 ;;
esac

LOG_DIR=".build/check"
mkdir -p "$LOG_DIR"
failed=()
started=$(date +%s)

step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }
fail() { failed+=("$1"); }

if ! git diff --quiet HEAD -- . 2>/dev/null; then
  echo "note: the working tree has uncommitted changes; this checks the tree, not HEAD."
fi

# 1. Lint ------------------------------------------------------------------------------------
step "lint"
Tools/lint.sh || fail "lint"

# 2. Generated models match their descriptors -------------------------------------------------
step "generated models"
python3 Tools/generate-models.py --check || fail "generated models drifted (python3 Tools/generate-models.py)"

# 3. Version consistency ----------------------------------------------------------------------
step "version"
Tools/check-version.sh || fail "version"

# 4. The builder did not touch the planner's tests ---------------------------------------------
step "planner tests"
Tools/guard-tests.sh || fail "planner tests edited"

# 5. Kit tests -------------------------------------------------------------------------------
if [[ "$mode" == "red" ]]; then
  step "kit tests (red: must compile, must fail)"
  if ! swift build --disable-sandbox --build-tests > "$LOG_DIR/build-tests.log" 2>&1; then
    grep -E "error:" "$LOG_DIR/build-tests.log" | sort -u | head -20
    echo "red: FAIL the tests do not compile. A compile error is not a red test: add the"
    echo "     signatures they need as stubs that return a wrong value or throw (not fatalError)."
    fail "red tests do not compile"
  else
    swift test --disable-sandbox > "$LOG_DIR/test.log" 2>&1
    rc=$?
    grep -E "^✘ Test .* (failed|recorded an issue)|error: -\[" "$LOG_DIR/test.log" | head -40
    if [[ $rc -eq 0 ]]; then
      echo "red: FAIL every test passed. A planner test that passes before the change guards nothing."
      fail "red tests are not red"
    elif grep -qE "(Fatal error|Exited with (signal|unexpected)|crashed)" "$LOG_DIR/test.log"; then
      echo "red: FAIL the test process crashed (see $LOG_DIR/test.log). A crash hides every result"
      echo "     after it; stub with a wrong value or a thrown error instead of fatalError."
      fail "red tests crash"
    else
      echo "red: ok the suite compiles and fails on assertions (full log: $LOG_DIR/test.log)."
    fi
  fi
else
  step "kit tests + coverage"
  if swift test --disable-sandbox --enable-code-coverage > "$LOG_DIR/test.log" 2>&1; then
    grep -E "^✔ Test run with|Executed [0-9]+ tests" "$LOG_DIR/test.log" | tail -2
    step "coverage"
    Tools/coverage.sh || fail "coverage"
  else
    grep -E "^✘ |error:" "$LOG_DIR/test.log" | head -40
    echo "(full log: $LOG_DIR/test.log)"
    fail "kit tests"
  fi
fi

# 6. App builds --------------------------------------------------------------------------------
if [[ "$mode" == "full" ]]; then
  if ! command -v xcodegen > /dev/null; then
    fail "xcodegen not installed (brew install xcodegen; see Tools/setup-dev.sh)"
  else
    (cd Apps/DSHRemote && xcodegen generate --quiet) || fail "xcodegen generate"
    for config in Debug Release; do
      step "app build ($config)"
      log="$LOG_DIR/app-$config.log"
      if xcodebuild -project Apps/DSHRemote/DSHRemote.xcodeproj -scheme DSHRemote \
          -configuration "$config" -destination 'generic/platform=iOS Simulator' \
          build > "$log" 2>&1; then
        echo "app: ok $config"
      else
        grep -E "error:" "$log" | sort -u | head -20
        echo "(full log: $log)"
        fail "app build $config"
      fi
    done
  fi
fi

# Summary --------------------------------------------------------------------------------------
elapsed=$(( $(date +%s) - started ))
echo
if [[ ${#failed[@]} -eq 0 ]]; then
  printf "\033[32mcheck: green (%s, %ss)\033[0m\n" "$mode" "$elapsed"
  exit 0
fi
printf "\033[31mcheck: RED (%s, %ss)\033[0m\n" "$mode" "$elapsed"
for f in "${failed[@]}"; do echo "  - $f"; done
exit 1
