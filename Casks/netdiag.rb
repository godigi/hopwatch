cask "netdiag" do
  version "0.14.0"
  sha256 :no_check

  url "https://github.com/godigi/netdiag/releases/download/v#{version}/Netdiag-#{version}.dmg"
  name "Netdiag"
  desc "Network diagnostics and menu bar monitor for macOS"
  homepage "https://github.com/godigi/netdiag"

  depends_on macos: ">= :sonoma"

  app "Netdiag.app"
  binary "#{appdir}/Netdiag.app/Contents/Resources/cli/bin/netdiag"

  zap trash: [
    "~/Library/Preferences/me.brianfreeman.netdiag.plist",
    "~/net-diag",
  ]
end
