require 'json'

class LanguagePack::Helpers::Nodebin
  NODE_VERSION = "22.11.0"
  YARN_VERSION = "1.22.22"

  def self.hardcoded_node_lts(arch: )
    version = case ENV.fetch("TARGET")
    when "ubuntu:18.04", "ubuntu:16.04", "el:7", "sles:12"
      "16.18.1"
    else
      NODE_VERSION
    end
    arch = "x64" if arch == "amd64"
    {
      "number" => version,
      "url"    => "https://nodejs.org/dist/v#{version}/node-v#{version}-linux-#{arch}.tar.gz"
    }
  end

  def self.hardcoded_yarn
    {
      "number" => YARN_VERSION,
      "url"    => "https://heroku-nodebin.s3.us-east-1.amazonaws.com/yarn/release/yarn-v#{YARN_VERSION}.tar.gz"
    }
  end

  def self.node_lts(arch: )
    hardcoded_node_lts(arch: arch)
  end

  def self.yarn
    hardcoded_yarn
  end
end
