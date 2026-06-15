# Homebrew Cask for Night Conductor.
#
# This is ready to publish once you cut a signed, notarized release. Steps:
#   1. Sign + notarize the app (see packaging/README.md), zip it as
#      Night-Conductor-<version>.zip, and attach it to a GitHub release.
#   2. Fill in `version` and the real `sha256` (shasum -a 256 <zip>).
#   3. Put this file in a tap repo: github.com/jkkorn/homebrew-tap →
#      Casks/night-conductor.rb. Then: brew install --cask jkkorn/tap/night-conductor
cask "night-conductor" do
  version "1.0.0"
  sha256 :no_check # replace with: shasum -a 256 Night-Conductor-1.0.0.zip

  url "https://github.com/jkkorn/Night-Conductor/releases/download/v#{version}/Night-Conductor-#{version}.zip"
  name "Night Conductor"
  desc "Resume Conductor sessions that hit the Claude usage limit, while you sleep"
  homepage "https://github.com/jkkorn/Night-Conductor"

  depends_on macos: ">= :sequoia"
  app "Night Conductor.app"

  zap trash: [
    "~/Library/Preferences/app.night-conductor.plist",
    "~/Library/LaunchAgents/com.autoconduct.agent.plist",
  ]
end
