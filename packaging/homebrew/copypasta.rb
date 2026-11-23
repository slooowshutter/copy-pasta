# CopyPasta's Homebrew cask, for the tap slooowshutter/homebrew-tap (as Casks/copypasta.rb):
#   brew install --cask slooowshutter/tap/copypasta
# This file is the template: on each release the release workflow copies it into the tap with
# that release's version and sha256 filled in, so change the cask here, not in the tap.
cask "copypasta" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/slooowshutter/copy-pasta/releases/download/v#{version}/CopyPasta.dmg"
  name "CopyPasta"
  desc "Clipboard history manager with pinboards and dictation"
  homepage "https://github.com/slooowshutter/copy-pasta"

  livecheck do
    url "https://github.com/slooowshutter/copy-pasta/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  # Sparkle updates the app in place; `brew upgrade` leaves it alone unless --greedy.
  auto_updates true
  depends_on macos: :sonoma

  app "CopyPasta.app"

  uninstall quit: "com.marclamy.copypasta"

  zap trash: [
    "~/Library/Application Support/CopyPasta",
    "~/Library/Caches/com.marclamy.copypasta",
    "~/Library/HTTPStorages/com.marclamy.copypasta",
    "~/Library/Preferences/com.marclamy.copypasta.plist",
  ]
end
