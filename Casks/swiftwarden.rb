cask "swiftwarden" do
  version "0.1.0"
  sha256 "9d5f995fff9fd40a1e781cb92f87c1303f0b10ed1c909c195592d9300962f885"

  url "https://github.com/list-jonas/Swiftwarden/releases/download/v#{version}/Swiftwarden-#{version}.zip"
  name "Swiftwarden"
  desc "Native Bitwarden client with autofill for other apps"
  homepage "https://github.com/list-jonas/Swiftwarden"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Swiftwarden.app"

  postflight_steps do
    run "/usr/bin/xattr", args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Swiftwarden.app"],
                          writable_paths: ["{{appdir}}/Swiftwarden.app"]
  end

  uninstall quit: "com.listjonas.swiftwarden"

  zap login_item: "Swiftwarden",
      trash:      [
        "~/Library/Application Support/Swiftwarden",
        "~/Library/Caches/Swiftwarden",
        "~/Library/Preferences/com.listjonas.swiftwarden.plist",
      ]

  caveats <<~EOS
    Swiftwarden is not signed with an Apple Developer ID. The cask removes the
    quarantine flag so macOS opens it. Autofill needs Accessibility access:
      System Settings > Privacy & Security > Accessibility
  EOS
end
