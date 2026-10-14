#!/bin/bash
# Version consistency (docs/process/RELEASING.md).
#
# Apps/DSHRemote/project.yml is the single source of truth for the version. This checks:
#   1. CFBundleShortVersionString is semver (X.Y.Z) and CFBundleVersion is a positive integer.
#   2. The committed Info.plist says the same thing. XcodeGen writes it from project.yml, and
#      it is committed, so it can drift — v0.2.0 was tagged on a tree whose plist still said
#      0.1.0 / 1 (fixed in 8ab6b3d).
#   3. The build number never goes backwards relative to the last v* tag.
#   4. If the version differs from the last tag's: it is greater, the build number is greater,
#      and CHANGELOG.md has a "## [X.Y.Z]" section for it.
#   5. If HEAD carries a v* tag, the tag names the version in project.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

YML="Apps/DSHRemote/project.yml"
PLIST="Apps/DSHRemote/Info.plist"
status=0
bad() { echo "version: FAIL $*"; status=1; }

yml_value() {  # key, [file contents on stdin]
  grep -E "^[[:space:]]*$1:" | head -1 | sed -E 's/^[^:]*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

short="$(yml_value CFBundleShortVersionString < "$YML")"
build="$(yml_value CFBundleVersion < "$YML")"

[[ "$short" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || bad "$YML CFBundleShortVersionString '$short' is not X.Y.Z"
[[ "$build" =~ ^[1-9][0-9]*$ ]] || bad "$YML CFBundleVersion '$build' is not a positive integer"

plist_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo '?')"
plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo '?')"
if [[ "$plist_short" != "$short" || "$plist_build" != "$build" ]]; then
  bad "$PLIST says $plist_short ($plist_build) but $YML says $short ($build)."
  echo "      Run 'cd Apps/DSHRemote && xcodegen generate' and commit Info.plist with the bump."
fi

# semver a > b ?
semver_gt() {
  local IFS=.
  local -a a=($1) b=($2)
  for i in 0 1 2; do
    (( a[i] > b[i] )) && return 0
    (( a[i] < b[i] )) && return 1
  done
  return 1
}

last_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
if [[ -n "$last_tag" ]]; then
  tag_yml="$(git show "$last_tag:$YML" 2>/dev/null || true)"
  tag_short="$(printf "%s\n" "$tag_yml" | yml_value CFBundleShortVersionString)"
  tag_build="$(printf "%s\n" "$tag_yml" | yml_value CFBundleVersion)"
  if [[ "$tag_build" =~ ^[0-9]+$ && "$build" =~ ^[0-9]+$ ]] && (( build < tag_build )); then
    bad "build number $build is lower than $tag_build at $last_tag; it only goes up."
  fi
  if [[ "$short" != "$tag_short" ]]; then
    semver_gt "$short" "$tag_short" || bad "version $short is not greater than $tag_short at $last_tag"
    if [[ "$tag_build" =~ ^[0-9]+$ && "$build" =~ ^[0-9]+$ ]] && (( build <= tag_build )); then
      bad "a new version ($short) needs a new build number (> $tag_build); use git rev-list --count HEAD"
    fi
    grep -qE "^## \[$short\]" CHANGELOG.md 2>/dev/null \
      || bad "CHANGELOG.md has no '## [$short]' section for the new version"
  fi
fi

head_tag="$(git tag --points-at HEAD --list 'v[0-9]*' | head -1)"
if [[ -n "$head_tag" && "$head_tag" != "v$short" ]]; then
  bad "HEAD is tagged $head_tag but $YML says $short"
fi

[[ $status -eq 0 ]] && echo "version: ok $short ($build); last tag ${last_tag:-none}"
exit $status
