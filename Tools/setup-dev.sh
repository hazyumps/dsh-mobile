#!/bin/bash
# One-time setup for a machine that will commit to this repo. Safe to run again.
#
#   Tools/setup-dev.sh
#
# It installs nothing; it checks the toolchain, and points this clone's git config at the
# versioned hook and signers file, by relative paths. Everything it sets is local to this clone
# (.git/config), and shared by its worktrees.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
problems=0
ok()   { printf "  \033[32mok\033[0m   %s\n" "$1"; }
warn() { printf "  \033[33mwarn\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31mmiss\033[0m %s\n" "$1"; problems=$((problems + 1)); }

echo "Toolchain"
if xcode-select -p > /dev/null 2>&1 && xcodebuild -version > /dev/null 2>&1; then
  ok "$(xcodebuild -version | head -1) at $(xcode-select -p)"
else
  bad "Xcode: install it from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"
fi
if command -v swift > /dev/null; then
  ok "$(swift --version 2>/dev/null | head -1)"
else
  bad "swift (comes with Xcode)"
fi
command -v xcodegen > /dev/null && ok "xcodegen $(xcodegen --version 2>/dev/null | tail -1)" \
  || bad "xcodegen: brew install xcodegen (the .xcodeproj is generated from project.yml)"
command -v python3 > /dev/null && ok "$(python3 --version)" \
  || bad "python3 (Tools/generate-models.py)"
# tea was how the original had its issues and PRs; it is not needed to build or test anything,
# and the instance it pointed at is private, so only mention it where `origin` is that instance.
if [[ "$(git remote get-url origin 2>/dev/null || true)" == *gitea.fernlabs.net* ]]; then
  if command -v tea > /dev/null; then
    logins="$(tea logins 2>/dev/null || true)"   # captured: `| grep -q` would SIGPIPE tea under pipefail
    if [[ "$logins" == *gitea.fernlabs.net* ]]; then ok "tea, logged in to gitea"
    else warn "tea is installed but not logged in: tea login add --url https://gitea.fernlabs.net"; fi
  else
    warn "tea (Gitea CLI, for issues and PRs from the terminal): brew install tea"
  fi
fi

# Tools/check.sh runs the app tests on a simulator of their own, "DSH Remote Tests", and creates
# it on its first run from the newest iOS runtime and an iPhone device type (#74).
echo "Simulator"
if listing="$(xcrun simctl list -j 2>/dev/null)" && command -v python3 > /dev/null; then
  sim="$(printf "%s" "$listing" | python3 -I -c '
import json, sys
listing = json.load(sys.stdin)
def version(runtime):
    try:
        return tuple(int(part) for part in runtime.get("version", "").split("."))
    except ValueError:
        return ()
runtimes = [
    r for r in listing.get("runtimes", [])
    if r.get("isAvailable")
    and (r.get("platform") == "iOS" or ".SimRuntime.iOS-" in r.get("identifier", ""))
]
if not runtimes:
    sys.exit("no-runtime")
runtime = max(runtimes, key=version)
types = runtime.get("supportedDeviceTypes") or listing.get("devicetypes", [])
iphones = [t["name"] for t in types if t.get("productFamily") == "iPhone"]
dedicated = any(
    d.get("name") == "DSH Remote Tests" and d.get("isAvailable")
    for group in listing.get("devices", {}).values() for d in group
)
print(runtime.get("name", runtime.get("identifier")), iphones[0] if iphones else "", "yes" if dedicated else "no", sep="|")
' 2>/dev/null)"
  IFS='|' read -r runtime iphone dedicated <<< "$sim"
  if [[ -z "$sim" ]]; then
    bad "an iOS simulator runtime: xcodebuild -downloadPlatform iOS (Tools/check.sh runs the app tests on one)"
  elif [[ -z "$iphone" ]]; then
    bad "an iPhone device type for $runtime: reinstall the runtime in Xcode > Settings > Components"
  else
    ok "$runtime simulator runtime, with an iPhone device type ($iphone)"
    if [[ "$dedicated" == "yes" ]]; then
      ok "\"DSH Remote Tests\" simulator exists (the app tests' own: never pair a host on it)"
    else
      ok "\"DSH Remote Tests\" simulator: Tools/check.sh creates it when it first runs the app tests"
    fi
  fi
else
  bad "xcrun simctl (comes with Xcode) and python3, to find an iOS simulator runtime"
fi

echo "Git"
# Both settings name a path in the checkout, and both must be relative. git resolves a relative
# value from the top of whichever worktree it runs in, so each worktree runs its own hook and
# verifies against its own .gitsigners. An absolute value sends every worktree to one checkout's
# copy, and this script used to write one for the signers file (#77). `git config` writes
# .git/config, which every worktree of this clone shares, so one run fixes them all.
set_relative() {   # <key> <value> <what it is for> <what the old value did>
  local key="$1" want="$2" why="$3" effect="$4" old now
  old="$(git config --get "$key")"
  # The old value may also come from ~/.gitconfig, which stays in effect for other repos.
  [[ -n "$old" && "$old" != "$want" ]] \
    && warn "$key was $old ($(git config --show-origin --get "$key" | cut -f1)): $effect. Setting $want."
  git config "$key" "$want"
  # Read the effective value back. A worktree's config.worktree, and GIT_CONFIG_* or `git -c` in
  # the environment, beat .git/config, so writing .git/config alone may not change what git uses.
  now="$(git config --get "$key")"
  if [[ "$now" == "$want" ]]; then
    ok "$key = $want ($why)"
  else
    bad "$key is still $now, from $(git config --show-origin --get "$key" | cut -f1), which overrides .git/config: unset it there"
  fi
}
set_relative core.hooksPath .githooks "pre-push runs Tools/check.sh" \
  "every worktree ran the hook from there"
set_relative gpg.ssh.allowedSignersFile .gitsigners "verifies teammates' signatures" \
  "every worktree verified signatures against that file"

if [[ "$(git config --get commit.gpgsign)" == "true" && -n "$(git config --get user.signingkey)" ]]; then
  ok "commit signing on ($(git config --get gpg.format || echo openpgp))"
  if [[ "$(git config --get gpg.format)" == "ssh" ]]; then
    key="$(git config --get user.signingkey)"
    pub="$( [[ -f "$key" ]] && cut -d' ' -f2 "$key" || echo "$key" | cut -d' ' -f2)"
    grep -qF "$pub" .gitsigners && ok "your signing key is in .gitsigners" \
      || warn "your signing key is not in .gitsigners yet; add it in your first PR"
  fi
  [[ "$(git config --get tag.gpgsign)" == "true" ]] || warn "tag.gpgsign is off: releases need signed tags (git config tag.gpgsign true)"
else
  bad "commit signing: every commit is signed (AGENTS.md). For an SSH key:
         git config gpg.format ssh
         git config user.signingkey ~/.ssh/<key>.pub
         git config commit.gpgsign true
         git config tag.gpgsign true"
fi

echo
if [[ $problems -eq 0 ]]; then
  echo "Ready. Try: Tools/check.sh --fast"
else
  echo "$problems thing(s) to fix above."
  exit 1
fi
