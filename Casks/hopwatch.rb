cask "hopwatch" do
  version "1.24.0"
  sha256 :no_check

  url "https://github.com/godigi/hopwatch/releases/download/v#{version}/Hopwatch-#{version}.dmg"
  name "Hopwatch"
  desc "Network diagnostics and menu bar monitor"
  homepage "https://godigi.github.io/hopwatch/"

  depends_on macos: :sonoma

  app "Hopwatch.app"
  binary "#{appdir}/Hopwatch.app/Contents/Resources/cli/bin/hopwatch"

  zap trash: [
    "~/hopwatch",
    "~/Library/Application Support/com.godigi.hopwatch",
    "~/Library/Preferences/com.godigi.hopwatch.plist",
    "~/net-diag",
  ]

  caveats <<~EOS
    Hopwatch requires Bash 5+ (macOS ships Bash 3.2):
      brew install bash

    Optional tools for full diagnostics (Ookla speedtest, per-hop mtr):
      brew install teamookla/speedtest/speedtest mtr gping
  EOS
end
