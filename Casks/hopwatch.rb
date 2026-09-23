cask "hopwatch" do
  version "1.7.2"
  sha256 :no_check

  url "https://github.com/godigi/hopwatch/releases/download/v#{version}/Hopwatch-#{version}.dmg"
  name "Hopwatch"
  desc "Network diagnostics and menu bar monitor for macOS"
  homepage "https://github.com/godigi/hopwatch"

  depends_on macos: ">= :sonoma"

  app "Hopwatch.app"
  binary "#{appdir}/Hopwatch.app/Contents/Resources/cli/bin/hopwatch"

  zap trash: [
    "~/Library/Application Support/com.godigi.hopwatch",
    "~/Library/Preferences/com.godigi.hopwatch.plist",
    "~/hopwatch",
    "~/net-diag",
  ]
end
