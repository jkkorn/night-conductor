# Packaging & distribution

Signing only affects the **binaries you ship**; the source stays MIT and
contributors keep building ad-hoc from source for free. Your account:
Apple ID `jkkorn@mac.com`, Team ID `Q7DSDANFTU`.

## One-time setup

### 1. Create a "Developer ID Application" certificate
You currently have only an *Apple Development* cert, which can't sign apps for
distribution outside the App Store. Create the Developer ID one:

- **Xcode** → Settings → Accounts → select `jkkorn@mac.com` → **Manage
  Certificates…** → **+** → **Developer ID Application**.

Confirm it landed:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```
`build-app.sh` auto-detects it from then on (hardened runtime, timestamp).

### 2. Store notarytool credentials
Create an app-specific password at appleid.apple.com → Sign-In and Security →
App-Specific Passwords. Then store it once (run in your terminal — the
password never leaves your machine):
```bash
xcrun notarytool store-credentials night-conductor \
  --apple-id jkkorn@mac.com --team-id Q7DSDANFTU --password <app-specific-password>
```

## Cut a release
```bash
cd NightConductor
./release.sh          # build → sign → notarize → staple → zip + print sha256
```
Then publish it and wire the cask (the script prints both commands):
```bash
gh release create vX.Y.Z "dist/Night-Conductor-X.Y.Z.zip" --generate-notes
# put version + sha256 into packaging/night-conductor.rb
```

## Homebrew
Create a tap repo `jkkorn/homebrew-tap`, add `Casks/night-conductor.rb`
(from `packaging/night-conductor.rb`). Users then:
```bash
brew install --cask jkkorn/tap/night-conductor
```

## Pay-what-you-want (optional, funds the $99/yr cert)
Keep the app free + open from source; offer the prebuilt notarized download
as pay-what-you-want (the Ice / Rectangle model).
