#!/bin/bash
# One-time setup for a machine that will commit to this repo. Safe to run again.
#
#   Tools/setup-dev.sh
#
# It installs nothing; it checks the toolchain, and points this clone's git config at the
# versioned hook and signers file. Everything it sets is local to this clone (.git/config).
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
if command -v tea > /dev/null; then
  logins="$(tea logins 2>/dev/null || true)"   # captured: `| grep -q` would SIGPIPE tea under pipefail
  if [[ "$logins" == *gitea.fernlabs.net* ]]; then ok "tea, logged in to gitea"
  else warn "tea is installed but not logged in: tea login add --url https://gitea.fernlabs.net"; fi
else
  warn "tea (Gitea CLI, for issues and PRs from the terminal): brew install tea"
fi

echo "Git"
git config core.hooksPath .githooks
ok "core.hooksPath = .githooks (pre-push runs Tools/check.sh)"
git config gpg.ssh.allowedSignersFile "$ROOT/.gitsigners"
ok "gpg.ssh.allowedSignersFile = .gitsigners (verifies teammates' signatures)"

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
