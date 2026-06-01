#!/usr/bin/env bash
# Bump waik's cask in the personal Homebrew tap and push.
#
# Invoked by the release workflow when HOMEBREW_TAP_TOKEN is present.
#
# Required environment:
#   HOMEBREW_TAP_TOKEN   – PAT with `repo` scope on joshuajomiller/homebrew-waik
#   GITHUB_REF_NAME      – e.g. v0.3.0
#   RUNNER_TEMP          – workspace dir (Actions sets this; falls back to /tmp)
#
# Inputs:
#   $1  Path to the release .zip (used to compute sha256)

set -euo pipefail

ZIP="${1:?missing zip path}"
TAP_REPO="${TAP_REPO:-joshuajomiller/homebrew-waik}"
TEMPLATE="${TEMPLATE:-Casks/waik.rb}"

if [ ! -f "$ZIP" ]; then
    echo "::error::zip not found: $ZIP"
    exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
    echo "::error::cask template not found: $TEMPLATE"
    exit 1
fi

VERSION="${GITHUB_REF_NAME#v}"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

WORK="${RUNNER_TEMP:-/tmp}/tap-repo"
rm -rf "$WORK"
git clone "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/${TAP_REPO}.git" "$WORK"

CASK_DEST="$WORK/Casks/waik.rb"
mkdir -p "$WORK/Casks"

# Render the cask: copy the in-repo template into the tap, then patch
# version and sha256 in place. Single source of truth lives in this repo.
cp "$TEMPLATE" "$CASK_DEST"

# Replace version and sha256 fields, regardless of starting value.
python3 - "$CASK_DEST" "$VERSION" "$SHA" <<'PY'
import re
import sys

path, version, sha = sys.argv[1:]
with open(path) as f:
    src = f.read()
src = re.sub(r'^( *version )"[^"]*"', rf'\1"{version}"', src, count=1, flags=re.MULTILINE)
src = re.sub(r'^( *sha256 ).+$',     rf'\1"{sha}"',     src, count=1, flags=re.MULTILINE)
with open(path, "w") as f:
    f.write(src)
PY

cd "$WORK"
git config user.name  "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add Casks/waik.rb

if git diff --staged --quiet; then
    echo "No cask changes — already at ${VERSION}."
    exit 0
fi

git commit -m "waik ${VERSION}

Bumped automatically from joshuajomiller/waik release ${GITHUB_REF_NAME}.
"
git push origin HEAD:main

echo "Pushed waik ${VERSION} to ${TAP_REPO}"
