require "yaml"
require "language_pack/shell_helpers"

module LanguagePack
  class Fetcher
    class FetchError < StandardError; end

    include ShellHelpers
    CDN_YAML_FILE = File.expand_path("../../../config/cdn.yml", __FILE__)

    def initialize(host_url, stack = nil)
      @config   = load_config
      @host_url = fetch_cdn(host_url)
      @host_url += File.basename(stack) if stack
    end

    def exists?(path, max_attempts = 1)
      curl = curl_command("-I #{@host_url.join(path)}")
      run!(curl, error_class: FetchError, max_attempts: max_attempts, silent: true)
    rescue FetchError
      false
    end

    def fetch(path)
      curl = curl_command("-O #{@host_url.join(path)}")
      run!(curl, error_class: FetchError)
    end

    def fetch_untar(path, files_to_extract = nil)
      curl = curl_command("#{@host_url.join(path)} -s -o")
      run! "#{curl} - | tar zxf - #{files_to_extract}",
        error_class: FetchError,
        max_attempts: 3
    end

    def fetch_bunzip2(path, files_to_extract = nil)
      curl = curl_command("#{@host_url.join(path)} -s -o")
      run!("#{curl} - | tar jxf - #{files_to_extract}", error_class: FetchError)
    end

    private
    def curl_command(command)
      binary, *rest = command.split(" ")
      buildcurl_mapping = {
        "ruby" => /^ruby-(.+)$/,
        "rubygem-bundler" => /^bundler-(.+)$/,
        "libyaml" => /^libyaml-(.+)$/
      }
      buildcurl_mapping.each do |k,v|
        if File.basename(binary, ".tgz") =~ v
          return "set -o pipefail; curl -L --get --fail --retry 3 #{buildcurl_url} -d recipe=#{k} -d version=#{$1} -d target=$TARGET #{rest.join(" ")}"
        end
      end
      "set -o pipefail; curl -L --fail --retry 3 --retry-delay 1 --connect-timeout #{curl_connect_timeout_in_seconds} --max-time #{curl_timeout_in_seconds} #{command}"
    end

    def buildcurl_url
      ENV['BUILDCURL_URL'] || "buildcurl.com"
    end

    def curl_timeout_in_seconds
      env('CURL_TIMEOUT') || 30
    end

    def curl_connect_timeout_in_seconds
      env('CURL_CONNECT_TIMEOUT') || 3
    end

    def load_config
      YAML.load_file(CDN_YAML_FILE) || {}
    end

    def fetch_cdn(url)
      url = @config[url] || url
      Pathname.new(url)
    end
  end
end
