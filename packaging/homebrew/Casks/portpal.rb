cask "portpal" do
  version "0.1.0"
  sha256 "REPLACE_WITH_PORTPAL_APP_ZIP_SHA256"

  url "https://github.com/itsfrank/portpal/releases/download/v#{version}/Portpal.app.zip"
  name "Portpal"
  desc "Menu bar utility for managing forwarded SSH ports"
  homepage "https://github.com/itsfrank/portpal"

  app "Portpal.app"
end
