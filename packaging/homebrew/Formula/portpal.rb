class Portpal < Formula
  desc "Manage forwarded SSH ports from the CLI and a macOS menu bar app"
  homepage "https://github.com/itsfrank/portpal"
  url "https://github.com/itsfrank/portpal/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_SOURCE_ARCHIVE_SHA256"
  license "MIT"
  head "https://github.com/itsfrank/portpal.git", branch: "main"

  depends_on :macos
  depends_on xcode: ["16.1", :build]

  def install
    system "swift", "build", "-c", "release", "--product", "portpal", "--product", "PortpalService"

    libexec.install ".build/release/PortpalService" => "Portpal/PortpalService"
    libexec.install ".build/release/portpal" => "portpal-bin"

    (bin/"portpal").write_env_script libexec/"portpal-bin",
      PORTPAL_SERVICE_PATH: libexec/"Portpal/PortpalService"
  end

  test do
    output = shell_output("#{bin}/portpal check --host brew-test --local-port 6553", 1)
    assert_match '"managed" : false', output
  end
end
