#!/bin/bash
# The builder does not edit, weaken, or delete the planner's tests (AGENTS.md).
#
#   Tools/guard-tests.sh [<base>]     # base defaults to the merge-base with origin/main
#
# The planner's tests land in commits whose subject starts with "Tests:". After the first such
# commit on a branch, any other (non-merge) commit that removes or changes a line in a file a
# "Tests:" commit touched fails this guard. Adding lines is fine: a builder may add tests.
# Changing a planner test is fine too — by the planner, in another "Tests:" commit, with the
# reason in its body (docs/process/WORKFLOW.md, step 4).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

base="${1:-}"
if [[ -z "$base" ]]; then
  base="$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main)"
fi

planner_files=""   # newline-separated paths touched by any "Tests:" commit so far
status=0
seen_tests_commit=0

for c in $(git rev-list --reverse --no-merges "$base"..HEAD); do
  subject="$(git log -1 --format=%s "$c")"
  if [[ "$subject" == Tests:* ]]; then
    seen_tests_commit=1
    while IFS= read -r f; do
      [[ -n "$f" ]] && planner_files="${planner_files}${f}"$'\n'
    done < <(git diff-tree --no-commit-id --name-only -r "$c" -- Tests/)
    continue
  fi
  [[ -z "$planner_files" ]] && continue
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ $'\n'"$planner_files" == *$'\n'"$f"$'\n'* ]] || continue
    removed="$(git diff "$c^" "$c" -- "$f" | grep -E '^-' | grep -vE '^--- ' || true)"
    if [[ -n "$removed" ]]; then
      echo "guard-tests: FAIL $(git log -1 --format='%h "%s"' "$c")"
      echo "             changes or removes lines in planner test file $f:"
      printf "%s\n" "$removed" | head -10 | sed 's/^/               /'
      status=1
    fi
  done < <(git diff-tree --no-commit-id --name-only -r "$c" -- Tests/)
done

if [[ $status -eq 0 ]]; then
  if [[ $seen_tests_commit -eq 1 ]]; then
    echo "guard-tests: ok (planner tests untouched since their Tests: commits)"
  else
    echo "guard-tests: ok (no Tests: commit on this branch)"
  fi
else
  echo "             If a planner test is wrong, the planner changes it in a new 'Tests:' commit"
  echo "             and says why. A builder never edits one."
fi
exit $status
