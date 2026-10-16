#!/bin/bash
# Cheap source checks for mistakes this repo has already made once. Each rule names the bug
# that motivated it. A known, tracked violation goes in Tools/lint-allowlist.txt with its issue
# number; an allowlist entry that no longer matches anything is itself an error, so the fix
# removes it.
#
# Rules:
#   retry-none   `retryPolicy: .none` against an optional parameter is Optional.none, which
#                means "the default, retrying policy" — the trap that retried approvals (#63).
#                Writes are never retried (AGENTS.md). Use `mutate`, or a write API with no
#                policy parameter.
#   optional-retry-policy
#                A declaration typed `RPCFailureRetryPolicy?` or
#                `Optional<RPCFailureRetryPolicy>` (comment lines excluded). An optional policy is
#                what made `.none` mean "the default, retrying policy" (#63). Writes take no
#                policy; a client's policy is non-optional.
#   debug-env    A `ProcessInfo...environment[...]` read in the app outside `#if DEBUG`. The
#                DSH_* launch variables are test affordances (Apps/DSHRemote/README.md); one
#                (DSH_ANSWER) can auto-approve an approval, so none may reach a release build.
#   kit-print    `print(` in DSHRemoteKit. The kit logs nothing: session content and tokens
#                pass through it (docs/process/RISK-FLAGS.md, flag 11).
#   host-lifecycle  The app building a `HostStore` or `KeychainSecretStore`, saving the host list,
#                or writing a relay token itself. The list and the token change together, in
#                `HostRegistry`, or they drift apart: a forget that edited memory and never saved
#                the list brought the host back, credential-less, on the next launch (#65).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ALLOW="Tools/lint-allowlist.txt"

hits=""   # lines of "<rule> <path>:<line>: <text>"

add() { hits="${hits}$1"$'\n'; }

# retry-none
while IFS= read -r line; do
  [[ -n "$line" ]] && add "retry-none $line"
done < <(grep -rnE 'retryPolicy:[[:space:]]*\.none\b' Sources Apps --include='*.swift' 2>/dev/null)

# optional-retry-policy (lines that are only a comment are skipped)
while IFS= read -r line; do
  [[ -n "$line" ]] && add "optional-retry-policy $line"
done < <(grep -rnE 'RPCFailureRetryPolicy[[:space:]]*\?|Optional[[:space:]]*<[[:space:]]*RPCFailureRetryPolicy[[:space:]]*>' \
  Sources Apps --include='*.swift' 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//')

# kit-print
while IFS= read -r line; do
  [[ -n "$line" ]] && add "kit-print $line"
done < <(grep -rnE '(^|[^.A-Za-z_])print\(' Sources/DSHRemoteKit --include='*.swift' 2>/dev/null \
  | grep -v '^Sources/DSHRemoteKit/Generated/')

# host-lifecycle
while IFS= read -r line; do
  [[ -n "$line" ]] && add "host-lifecycle $line"
done < <(grep -rnE '\bHostStore\(|KeychainSecretStore\(|\.save\(hosts|(set|delete)RelayDeviceToken\(' Apps \
  --include='*.swift' 2>/dev/null)

# debug-env: track `#if DEBUG` nesting per file. A line counts as debug-only when any enclosing
# conditional block is a DEBUG branch (and not its #else).
while IFS= read -r file; do
  while IFS= read -r line; do
    [[ -n "$line" ]] && add "debug-env $line"
  done < <(awk -v file="$file" '
    function indebug(  i) { for (i = 1; i <= depth; i++) if (stack[i] == 1) return 1; return 0 }
    /^[[:space:]]*#if[[:space:]]/ {
      depth++; stack[depth] = ($0 ~ /#if[[:space:]]+DEBUG([[:space:]]|$)/) ? 1 : 0; next
    }
    /^[[:space:]]*#elseif/ { if (depth) stack[depth] = 0; next }
    /^[[:space:]]*#else/   { if (depth) stack[depth] = 0; next }
    /^[[:space:]]*#endif/  { if (depth) depth--; next }
    /processInfo\.environment/ && !indebug() {
      text = $0; gsub(/^[[:space:]]+/, "", text); printf "%s:%d: %s\n", file, NR, text
    }
  ' "$file")
done < <(find Apps -name '*.swift' -not -path '*/.build*' -not -path '*/DerivedData/*' | sort)

# Apply the allowlist. Each entry: "<rule> <path> <count> <issue>  # why". The count is exact:
# one more hit in that file is a new violation, one fewer means the entry must be lowered or
# removed. A per-file entry without a count would hide the next violation in the same file.
status=0
counts="$(printf "%s" "$hits" | awk 'NF { split($2, a, ":"); print $1 " " a[1] }' | sort | uniq -c \
  | awk '{ print $2 " " $3 " " $1 }')"   # "<rule> <path> <n>"

allowed_count() {  # rule path -> count from the allowlist, or empty
  awk -v r="$1" -v p="$2" '$1 == r && $2 == p { print $3 }' "$ALLOW" 2>/dev/null
}

report=""
while read -r rule path n; do
  [[ -z "${rule:-}" ]] && continue
  allowed="$(allowed_count "$rule" "$path")"
  if [[ -z "$allowed" || "$n" -gt "$allowed" ]]; then
    report="${report}$(printf "%s" "$hits" | awk -v r="$rule" -v p="$path" '$1 == r && index($2, p ":") == 1 { print "  " $0 }')"$'\n'
    [[ -n "$allowed" ]] && report="${report}  (allowlist permits $allowed for '$rule $path'; found $n)"$'\n'
    status=1
  fi
done <<< "$counts"

if [[ $status -ne 0 ]]; then
  echo "lint: FAIL"
  printf "%s" "$report"
  echo "  See the rule descriptions at the top of Tools/lint.sh. A deliberate, tracked exception"
  echo "  goes in $ALLOW with an exact count and its issue number."
fi

# Allowlist entries the code no longer needs: the fix landed, so the entry goes too.
while read -r rule path allowed issue _; do
  [[ -z "${rule:-}" || "$rule" == \#* ]] && continue
  n="$(printf "%s\n" "$counts" | awk -v r="$rule" -v p="$path" '$1 == r && $2 == p { print $3 }')"
  n="${n:-0}"
  if [[ "$n" -lt "$allowed" ]]; then
    echo "lint: FAIL allowlist entry '$rule $path' ($issue) permits $allowed but only $n remain;"
    echo "      lower the count, or remove the entry if none remain."
    status=1
  fi
done < "$ALLOW"

[[ $status -eq 0 ]] && echo "lint: ok"
exit $status
