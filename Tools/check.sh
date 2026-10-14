#!/bin/bash
# The single definition of "green" for this repo. The pre-push hook runs it; a future CI runner
# should call exactly this script and nothing else, so the laptop and the server cannot disagree.
#
#   Tools/check.sh          # everything (about 4–6 min cold, ~1.5 min warm)
#   Tools/check.sh --fast   # everything except the app builds and app tests (~30 s, no simulator)
#   Tools/check.sh --red    # for a planner's "Tests:" commit: the kit tests and the app tests must
#                           # both COMPILE, nothing may crash, and at least one suite must FAIL on
#                           # assertions. A compile error is not red, it is broken (WORKFLOW.md step 2).
#
# Steps, in order of cost: lint, generated-model drift, version consistency, planner-test guard,
# kit tests with coverage, coverage ratchet + must-test floors, app build Debug + Release, app
# tests (Tests/DSHRemoteTests, hosted in the app, on an iOS simulator).
#
# The app tests run on DSH_TEST_SIMULATOR (a simulator UDID) if it is set. Otherwise they run on a
# simulator of their own, "DSH Remote Tests", created on the first run (newest iOS runtime, an
# iPhone) and reused after. It is for these tests only: the test bundle launches the real app,
# which reconnects any host paired on that simulator, so never pair a host there or use it for
# DSH_* review. A simulator this script boots, it shuts down again.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mode="full"
case "${1:-}" in
  --fast) mode="fast" ;;
  --red) mode="red" ;;
  "" | --full) ;;
  -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
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

APP_PROJECT="Apps/DSHRemote/DSHRemote.xcodeproj"
TEST_SIMULATOR_NAME="DSH Remote Tests"

# The project is generated, never committed (AGENTS.md). Once per run, for the app steps.
project_ready=""
generate_project() {
  if [[ -z "$project_ready" ]]; then
    if ! command -v xcodegen > /dev/null; then
      echo "xcodegen not installed (brew install xcodegen; see Tools/setup-dev.sh)"
      project_ready="no"
    elif (cd Apps/DSHRemote && xcodegen generate --quiet); then
      project_ready="yes"
    else
      echo "xcodegen generate failed"
      project_ready="no"
    fi
  fi
  [[ "$project_ready" == "yes" ]]
}

# Chooses the app tests' simulator from `xcrun simctl list -j` on stdin. Prints "use <udid>
# <state> <name>" or "create <device type> <runtime>"; anything it cannot do exits 1 with a hint.
SIMULATOR_PY='
import json, sys

wanted, name = sys.argv[1], sys.argv[2]
listing = json.load(sys.stdin)
devices = [
    device
    for runtime, group in listing.get("devices", {}).items()
    if ".SimRuntime.iOS-" in runtime
    for device in group
    if device.get("isAvailable")
]

if wanted:
    for device in devices:
        if device.get("udid") == wanted:
            print("use", device["udid"], device.get("state", "unknown"), device.get("name", ""))
            sys.exit(0)
    sys.exit(
        f"DSH_TEST_SIMULATOR={wanted} names no available iOS simulator. Pick a UDID from "
        f"`xcrun simctl list devices available`, or unset it to use \"{name}\"."
    )

# Never the first available simulator: that is the one used for DSH_* review (#74).
for device in devices:
    if device.get("name") == name:
        print("use", device["udid"], device.get("state", "unknown"), device.get("name", ""))
        sys.exit(0)

def version(runtime):
    try:
        return tuple(int(part) for part in runtime.get("version", "").split("."))
    except ValueError:
        return ()

runtimes = [
    runtime
    for runtime in listing.get("runtimes", [])
    if runtime.get("isAvailable")
    and (runtime.get("platform") == "iOS" or ".SimRuntime.iOS-" in runtime.get("identifier", ""))
]
if not runtimes:
    sys.exit(
        f"no iOS simulator runtime is installed, so \"{name}\" cannot be created. "
        "Install one with `xcodebuild -downloadPlatform iOS` (Tools/setup-dev.sh checks for it)."
    )
runtime = max(runtimes, key=version)
types = runtime.get("supportedDeviceTypes") or listing.get("devicetypes", [])
iphones = [t for t in types if t.get("productFamily") == "iPhone"]
if not iphones:
    label = runtime.get("name", "the newest iOS runtime")
    sys.exit(
        f"{label} supports no iPhone device type, so \"{name}\" cannot be created. "
        "Reinstall the runtime in Xcode > Settings > Components."
    )
print("create", iphones[0]["identifier"], runtime["identifier"])
'

# Sets test_simulator (a UDID) and test_simulator_state, creating the dedicated simulator when
# DSH_TEST_SIMULATOR is unset and it does not exist yet.
test_simulator=""
test_simulator_state=""
choose_test_simulator() {
  local listing answer verb a b c
  if ! listing="$(xcrun simctl list -j 2>/dev/null)"; then
    echo "xcrun simctl failed: is Xcode installed and selected? (Tools/setup-dev.sh)"
    return 1
  fi
  answer="$(printf "%s" "$listing" | python3 -I -c "$SIMULATOR_PY" "${DSH_TEST_SIMULATOR:-}" "$TEST_SIMULATOR_NAME" 2>&1)" || {
    echo "$answer"
    return 1
  }
  read -r verb a b c <<< "$answer"
  if [[ "$verb" == "use" ]]; then
    test_simulator="$a"
    test_simulator_state="$b"
    echo "simulator: ${DSH_TEST_SIMULATOR:+DSH_TEST_SIMULATOR=}$a \"$c\" ($b)"
  elif [[ "$verb" == "create" ]]; then
    if ! test_simulator="$(xcrun simctl create "$TEST_SIMULATOR_NAME" "$a" "$b" 2>&1)"; then
      echo "xcrun simctl create \"$TEST_SIMULATOR_NAME\" $a $b failed: $test_simulator"
      return 1
    fi
    test_simulator_state="Shutdown"
    echo "simulator: created \"$TEST_SIMULATOR_NAME\" $test_simulator ($a, $b)"
  else
    echo "could not choose a simulator: $answer"
    return 1
  fi
}

# Builds and runs the app test target (Tests/DSHRemoteTests). Compiling and running are separate
# xcodebuild calls, so a compile error and a failing test cannot be mistaken for each other.
# Sets app_tests to one of: pass, fail (on assertions), compile, crash, not-run.
app_tests=""
run_app_tests() {
  local build_log="$LOG_DIR/app-tests-build.log" test_log="$LOG_DIR/app-tests.log" rc
  if ! generate_project; then app_tests="not-run"; return; fi
  if ! xcodebuild -project "$APP_PROJECT" -scheme DSHRemote -configuration Debug \
      -destination 'generic/platform=iOS Simulator' build-for-testing > "$build_log" 2>&1; then
    grep -E "error:" "$build_log" | sort -u | head -20
    if [[ "$mode" == "red" ]]; then
      echo "red: FAIL the app tests do not compile. A compile error is not a red test: make what they"
      echo "     need internal, or add it as a stub that returns a wrong value (full log: $build_log)."
    else
      echo "app tests: FAIL the app or Tests/DSHRemoteTests does not compile (full log: $build_log)"
    fi
    app_tests="compile"
    return
  fi
  if ! choose_test_simulator; then app_tests="not-run"; return; fi
  xcodebuild -project "$APP_PROJECT" -scheme DSHRemote -configuration Debug \
    -destination "id=$test_simulator" -parallel-testing-enabled NO \
    -only-testing:DSHRemoteTests test-without-building > "$test_log" 2>&1
  rc=$?
  # Leave the simulator as it was found: a stray booted test simulator would answer
  # `xcrun simctl … booted` in place of the one being reviewed.
  if [[ "$test_simulator_state" != "Booted" ]]; then
    xcrun simctl shutdown "$test_simulator" > /dev/null 2>&1
  fi
  grep -E "^✘ |^✔ Test run with|Test Case .* failed|error: -\[" "$test_log" | head -40
  if [[ $rc -eq 0 ]]; then
    echo "app tests: ok"
    app_tests="pass"
  elif grep -qE "(Fatal error|crashed|unexpected exit|Exited with (signal|unexpected))" "$test_log"; then
    echo "app tests: FAIL the test process crashed (full log: $test_log). A crash hides every"
    echo "           result after it; stub with a wrong value or a thrown error, not fatalError."
    app_tests="crash"
  elif grep -qE "^✘ Test .* (failed|recorded an issue)|Test Case .* failed" "$test_log"; then
    if [[ "$mode" == "red" ]]; then
      echo "app tests: fail on assertions (full log: $test_log)"
    else
      echo "app tests: FAIL a test failed (full log: $test_log)"
    fi
    app_tests="fail"
  else
    grep -E "error|Error|failed" "$test_log" | sort -u | head -10
    echo "app tests: FAIL the tests did not run (full log: $test_log)"
    app_tests="not-run"
  fi
}

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
  # Red mode judges the kit and app suites together, below: either one may hold the red tests.
  kit_tests=""
  step "kit tests (red: must compile)"
  if ! swift build --disable-sandbox --build-tests > "$LOG_DIR/build-tests.log" 2>&1; then
    grep -E "error:" "$LOG_DIR/build-tests.log" | sort -u | head -20
    echo "red: FAIL the kit tests do not compile. A compile error is not a red test: add the"
    echo "     signatures they need as stubs that return a wrong value or throw (not fatalError)."
    fail "red tests do not compile (kit)"
    kit_tests="compile"
  else
    swift test --disable-sandbox > "$LOG_DIR/test.log" 2>&1
    rc=$?
    grep -E "^✘ Test .* (failed|recorded an issue)|error: -\[" "$LOG_DIR/test.log" | head -40
    if [[ $rc -eq 0 ]]; then
      echo "kit tests: all pass"
      kit_tests="pass"
    elif grep -qE "(Fatal error|Exited with (signal|unexpected)|crashed)" "$LOG_DIR/test.log"; then
      echo "red: FAIL the kit test process crashed (see $LOG_DIR/test.log). A crash hides every"
      echo "     result after it; stub with a wrong value or a thrown error instead of fatalError."
      fail "red tests crash (kit)"
      kit_tests="crash"
    else
      echo "kit tests: fail on assertions (full log: $LOG_DIR/test.log)"
      kit_tests="fail"
    fi
  fi

  step "app tests (red: must compile)"
  run_app_tests
  case "$app_tests" in
    compile) fail "red tests do not compile (app)" ;;
    crash) fail "red tests crash (app)" ;;
    not-run) fail "app tests did not run" ;;
  esac

  step "red"
  if [[ "$kit_tests" == "pass" && "$app_tests" == "pass" ]]; then
    echo "red: FAIL every test passed. A planner test that passes before the change guards nothing."
    fail "red tests are not red"
  elif [[ "$kit_tests" == "fail" || "$app_tests" == "fail" ]] \
      && [[ "$kit_tests" =~ ^(pass|fail)$ && "$app_tests" =~ ^(pass|fail)$ ]]; then
    echo "red: ok it compiles and fails on assertions (kit: $kit_tests, app: $app_tests; logs in $LOG_DIR)."
  else
    echo "red: FAIL see above (kit: ${kit_tests:-not run}, app: ${app_tests:-not run})."
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

# 6. App builds and app tests -------------------------------------------------------------------
if [[ "$mode" == "full" ]]; then
  if ! generate_project; then
    fail "xcodegen (see Tools/setup-dev.sh)"
  else
    debug_built=0
    for config in Debug Release; do
      step "app build ($config)"
      log="$LOG_DIR/app-$config.log"
      if xcodebuild -project "$APP_PROJECT" -scheme DSHRemote \
          -configuration "$config" -destination 'generic/platform=iOS Simulator' \
          build > "$log" 2>&1; then
        echo "app: ok $config"
        [[ "$config" == "Debug" ]] && debug_built=1
      else
        grep -E "error:" "$log" | sort -u | head -20
        echo "(full log: $log)"
        fail "app build $config"
      fi
    done

    step "app tests"
    if [[ $debug_built -eq 0 ]]; then
      echo "app tests: skipped, the Debug build failed"
    else
      run_app_tests
      case "$app_tests" in
        pass) ;;
        fail) fail "app tests" ;;
        compile) fail "app tests do not compile" ;;
        crash) fail "app tests crash" ;;
        *) fail "app tests did not run" ;;
      esac
    fi
  fi
fi

# Summary --------------------------------------------------------------------------------------
elapsed=$(( $(date +%s) - started ))
echo
if [[ ${#failed[@]} -eq 0 ]]; then
  if [[ "$mode" == "red" ]]; then
    # Not "green": the suite is red, which is what a Tests: commit must be.
    printf "\033[32mcheck: ok — red for the right reason (%ss)\033[0m\n" "$elapsed"
  else
    printf "\033[32mcheck: green (%s, %ss)\033[0m\n" "$mode" "$elapsed"
  fi
  exit 0
fi
printf "\033[31mcheck: RED (%s, %ss)\033[0m\n" "$mode" "$elapsed"
for f in "${failed[@]}"; do echo "  - $f"; done
exit 1
