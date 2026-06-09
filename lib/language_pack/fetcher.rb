require "yaml"
require "language_pack/shell_helpers"

module LanguagePack
  class Fetcher
    class FetchError < StandardError; end

    include ShellHelpers

    def initialize(host_url, stack: nil, arch: nil)
      @host_url = Pathname.new(host_url)
      # File.basename prevents accidental directory traversal
      @host_url += File.basename(stack) if stack
      @host_url += File.basename(arch) if arch
    end

    def exists?(path, max_attempts = 1)
      curl = curl_command("--head #{@host_url.join(path)}")
      run!(curl, error_class: FetchError, max_attempts: max_attempts, silent: true)
    rescue FetchError
      false
    end

    def fetch(path)
      curl = curl_command("--remote-name #{@host_url.join(path)}")
      run!(curl, error_class: FetchError)
    end

    def fetch_untar(path, files_to_extract = nil, strip_components: 0)
      curl = curl_command("#{@host_url.join(path)} --no-progress-meter --output")
      tar_cmd = ["tar", "--strip-components=#{strip_components}", "-xzf", "- #{files_to_extract}"]
      run! "#{curl} - | #{tar_cmd.join(" ")}",
        error_class: FetchError,
        max_attempts: 3
    end

    def fetch_bunzip2(path, files_to_extract = nil)
      curl = curl_command("#{@host_url.join(path)} --no-progress-meter --output")
      run!("#{curl} - | tar jxf - #{files_to_extract}", error_class: FetchError)
    end

    private

    def curl_command(command)
      binary, *rest = command.split(" ")
      buildcurl_mapping = {
        "ruby" => /^ruby-(.+)$/,
        "rubygem-bundler" => /^bundler-(.+)$/,
        "libyaml" => /^libyaml-(.+)$/,
        "node" => /^node-v(.+)-linux.+$/,
      }
      buildcurl_mapping.each do |k,v|
        if File.basename(binary, ".tgz") =~ v || File.basename(binary, ".tar.gz") =~ v
          return "set -o pipefail; curl -L --get --fail --retry 3 #{buildcurl_url} -d recipe=#{k} -d version=#{$1} -d target=$TARGET #{rest.join(" ")}"
        end
      end
      "set -o pipefail; curl -L --fail --retry 3 --retry-delay 1 --connect-timeout #{curl_connect_timeout_in_seconds} --max-time #{curl_timeout_in_seconds} #{command}"
    end

    def buildcurl_url
      ENV['BUILDCURL_URL'] || "buildcurl.com"
    end

    def curl_timeout_in_seconds
      env("CURL_TIMEOUT") || 30
    end

    def curl_connect_timeout_in_seconds
      env("CURL_CONNECT_TIMEOUT") || 3
    end
  end
end
