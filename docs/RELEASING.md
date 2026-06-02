# Releasing waik

This doc covers the maintainer pipeline: cutting a release, enabling Developer ID signing + notarization, Sparkle auto-updates, and the Homebrew cask. None of this is required for local dev — `Scripts/build.sh` produces an ad-hoc-signed bundle that runs fine on your own machine.

## Cutting a release

Tag a version and push:

```bash
git tag v0.4.0 && git push --tags
```

The `Release` workflow builds, signs, packages, and publishes a GitHub Release with the `.app.zip` + sha256 attached. Signing mode is chosen automatically from the secrets you've set:

| Mode | Trigger | Result |
|---|---|---|
| **Ad-hoc** (default) | `DEVELOPER_ID_CERT_P12_BASE64` not set | Gatekeeper warns users on first launch; they right-click → Open |
| **Developer ID + notarized** | All five secrets below set | Released `.app` launches cleanly everywhere |

## Developer ID signing + notarization

To switch on signed + notarized releases, add these repo secrets at **Settings → Secrets and variables → Actions**:

| Secret | How to generate |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | Export your *Developer ID Application* cert from Keychain Access (right-click → Export, choose `.p12`, set a password). Then `base64 < cert.p12 \| pbcopy` and paste. |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you set on the `.p12`. |
| `WAIK_TEAM_ID` | Your 10-character Apple Developer Team ID (Membership page on developer.apple.com). |
| `AC_APPLE_ID` | The Apple ID associated with your developer account. |
| `AC_APP_SPECIFIC_PASSWORD` | Generate at appleid.apple.com → Sign-In and Security → App-Specific Passwords. Used by `notarytool`. |

Once all five are present, the next tagged release auto-notarizes and staples without any code changes.

## Sparkle auto-updates

`waik` ships with Sparkle 2 integration ready to go — the menu has a "Check for updates…" item and the app respects `SUEnableAutomaticChecks`. To actually serve updates you need to generate an EdDSA signing key pair and host the appcast:

1. Download Sparkle's tarball: <https://github.com/sparkle-project/Sparkle/releases>
2. Generate a keypair: `./bin/generate_keys`. The public key prints to stdout; the private key is stored in your Keychain by default. Export the private key with `./bin/generate_keys -x sparkle.key`.
3. Paste the **public** key into `Resources/Info.plist`:
   ```xml
   <key>SUPublicEDKey</key>
   <string>YOUR_PUBLIC_KEY_HERE</string>
   ```
4. Add the **private** key as a GitHub repo secret named `SPARKLE_ED_PRIVATE_KEY` (paste the file contents).
5. Enable GitHub Pages on the `gh-pages` branch (repo Settings → Pages → Source: Deploy from a branch → `gh-pages`).
6. Cut a new release. The workflow signs the .zip, appends an entry to `gh-pages/appcast.xml`, and pushes. Existing users running `waik` will see the update on the next periodic check.

Until you complete those steps, the in-app "Check for updates…" item gracefully reports "Unable to check" — fail-closed by design.

## Homebrew cask

1. Create an empty public repo at `joshuajomiller/homebrew-waik` (Homebrew taps must use that prefix).
2. Generate a fine-grained Personal Access Token with **Contents: read & write** scope on that single repo.
3. Add it as a repo secret named `HOMEBREW_TAP_TOKEN`.
4. Cut a release. The workflow renders `Casks/waik.rb` with the new version + sha256 and pushes to `joshuajomiller/homebrew-waik`.

Users can then install with `brew tap joshuajomiller/waik && brew install --cask waik`. The cask in this repo is the source of truth — edit it here, and every subsequent release picks up the changes automatically.
