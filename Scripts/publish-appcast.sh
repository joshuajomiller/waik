#!/usr/bin/env bash
# Push a new appcast.xml entry to the gh-pages branch for the just-released
# version. Invoked by the release workflow when SPARKLE_ED_PRIVATE_KEY is
# present.
#
# Required environment:
#   SPARKLE_ED_PRIVATE_KEY   – base64 EdDSA private key from `generate_keys`
#   GITHUB_TOKEN             – auto-provided in Actions, needs `contents: write`
#   GITHUB_REPOSITORY        – e.g. joshuajomiller/waik
#   GITHUB_REF_NAME          – e.g. v0.3.0
#   RUNNER_TEMP              – workspace dir (Actions sets this; falls back to /tmp)
#
# Inputs:
#   $1  Path to the release .zip
#   $2  Path to the sign_update binary (from Sparkle's tarball)

set -euo pipefail

ARTIFACT="${1:?missing artifact path}"
SIGN_UPDATE="${2:?missing sign_update path}"
WORK_DIR="${RUNNER_TEMP:-/tmp}"

if [ ! -f "$ARTIFACT" ]; then
    echo "::error::artifact not found: $ARTIFACT"
    exit 1
fi

KEY_FILE="$WORK_DIR/sparkle.key"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

VERSION="${GITHUB_REF_NAME#v}"
DOWNLOAD_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${GITHUB_REF_NAME}/$(basename "$ARTIFACT")"
LENGTH="$(stat -f%z "$ARTIFACT")"
PUBDATE="$(date -R)"

# sign_update prints `sparkle:edSignature="..." length="..."` on success.
# Capture stdout and extract the signature attribute.
SIGN_OUTPUT="$("$SIGN_UPDATE" -f "$KEY_FILE" "$ARTIFACT")"
SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
if [ -z "$SIGNATURE" ]; then
    echo "::error::sign_update produced no signature. Output: $SIGN_OUTPUT"
    exit 1
fi

ITEM_FILE="$WORK_DIR/appcast-item.xml"
cat > "$ITEM_FILE" <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUBDATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url="${DOWNLOAD_URL}"
                length="${LENGTH}"
                type="application/octet-stream"
                sparkle:edSignature="${SIGNATURE}" />
        </item>
EOF

REPO_DIR="$WORK_DIR/appcast-repo"
rm -rf "$REPO_DIR"

git config --global user.name  "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"

CLONE_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

if git clone --branch gh-pages --depth 1 "$CLONE_URL" "$REPO_DIR" 2>/dev/null; then
    cd "$REPO_DIR"
else
    # gh-pages doesn't exist yet — bootstrap it as an orphan branch.
    git clone --depth 1 "$CLONE_URL" "$REPO_DIR"
    cd "$REPO_DIR"
    git checkout --orphan gh-pages
    git rm -rf . 2>/dev/null || true
fi

if [ ! -f appcast.xml ]; then
    cat > appcast.xml <<'TEMPLATE'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>waik</title>
        <description>Automatic updates for waik.</description>
        <language>en</language>
    </channel>
</rss>
TEMPLATE
fi

# Insert the new <item> just before </channel>.
awk -v item_file="$ITEM_FILE" '
    /<\/channel>/ {
        while ((getline line < item_file) > 0) print line
    }
    { print }
' appcast.xml > appcast.xml.new
mv appcast.xml.new appcast.xml

git add appcast.xml
git commit -m "appcast: add ${GITHUB_REF_NAME}"
git push -u origin gh-pages

echo "Published ${GITHUB_REF_NAME} to gh-pages/appcast.xml"
