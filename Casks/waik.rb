cask "waik" do
  version "0.3.1"
  sha256 :no_check

  url "https://github.com/joshuajomiller/waik/releases/download/v#{version}/waik-v#{version}.zip"
  name "waik"
  desc "Keep your Mac awake while your coding agent is working"
  homepage "https://github.com/joshuajomiller/waik"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Sparkle handles in-app updates once installed.
  auto_updates true
  depends_on macos: ">= :ventura"

  app "waik.app"

  zap trash: [
    "~/Library/Preferences/com.waik.app.plist",
    "~/Library/Application Support/com.waik.app",
    "~/Library/Caches/com.waik.app",
    "~/Library/Logs/com.waik.app",
  ]
end
