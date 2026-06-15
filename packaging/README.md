# Packaging & distribution

## Signing (keeps it open source)

Signing only affects the **binaries you ship**; the source stays MIT. The
Developer ID cert is a secret — store it in GitHub Actions, never in the repo.
Contributors keep building from source (ad-hoc) for free.

One-time: enroll in the Apple Developer Program ($99/yr), create a
"Developer ID Application" certificate.

Per release:
```bash
# build
NightConductor/build-app.sh
APP="NightConductor/dist/Night Conductor.app"

# sign + notarize
codesign --deep --force --options runtime --timestamp \
  --sign "Developer ID Application: <Your Name> (<TEAMID>)" "$APP"
ditto -c -k --keepParent "$APP" "Night-Conductor-<version>.zip"
xcrun notarytool submit "Night-Conductor-<version>.zip" \
  --apple-id <you@apple.id> --team-id <TEAMID> --password <app-specific-pw> --wait
xcrun stapler staple "$APP"
# re-zip the stapled app for distribution
ditto -c -k --keepParent "$APP" "Night-Conductor-<version>.zip"
```

## GitHub release + Homebrew

1. Attach `Night-Conductor-<version>.zip` to a GitHub release tagged `v<version>`.
2. `shasum -a 256 Night-Conductor-<version>.zip` → put in `night-conductor.rb`.
3. Create a tap repo `jkkorn/homebrew-tap`, add `Casks/night-conductor.rb`.
4. Users: `brew install --cask jkkorn/tap/night-conductor`.

## Pay-what-you-want (optional, funds the $99 cert)

Keep the app free + open from source. Offer the **prebuilt, notarized**
download as pay-what-you-want on Gumroad — people happily pay for the
convenience, the way Ice / Rectangle do.
