cask "hopwatch" do
  version "1.3.1"
  sha256 :no_check

  url "https://github.com/godigi/hopwatch/releases/download/v#{version}/Hopwatch-#{version}.dmg"
  name "Hopwatch"
  desc "Network diagnostics and menu bar monitor for macOS"
  homepage "https://github.com/godigi/hopwatch"

  depends_on macos: ">= :sonoma"

  app "Hopwatch.app"
  binary "#{appdir}/Hopwatch.app/Contents/Resources/cli/bin/hopwatch"
  binary "#{appdir}/Hopwatch.app/Contents/Resources/cli/bin/netdiag"

  zap trash: [
    "~/Library/Preferences/me.brianfreeman.hopwatch.plist",
    "~/Library/Preferences/me.brianfreeman.netdiag.plist",
    "~/hopwatch",
    "~/net-diag",
  ]
end
