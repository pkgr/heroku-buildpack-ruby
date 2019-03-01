require 'json'

class LanguagePack::Helpers::Nodebin
  NODE_VERSION = "20.9.0"
  YARN_VERSION = "1.22.19"

  def self.hardcoded_node_lts
    version = case ENV.fetch("TARGET")
    when "ubuntu:18.04", "ubuntu:16.04", "el:7", "sles:12"
      "16.18.1"
    else
      "18.16.1"
    end
    {
      "number" => version,
      "url"    => "https://nodejs.org/dist/v#{version}/node-v#{version}-linux-x64.tar.gz"
    }
  end

  def self.hardcoded_yarn
    {
      "number" => YARN_VERSION,
      "url"    => "https://heroku-nodebin.s3.us-east-1.amazonaws.com/yarn/release/yarn-v#{YARN_VERSION}.tar.gz"
    }
  end

  def self.node_lts
    hardcoded_node_lts
  end

  def self.yarn
    hardcoded_yarn
  end
end
