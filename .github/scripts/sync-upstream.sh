#!/usr/bin/env bash

set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/heroku/heroku-buildpack-ruby.git}"
PUSH_CHANGES="${PUSH_CHANGES:-1}"
SOURCE_REF="${SOURCE_REF:-HEAD}"
DEFAULT_RUBY_BUMP_COMMIT="${DEFAULT_RUBY_BUMP_COMMIT:-fc500664466eef57a3b457c2a5c7edbb9082013c}"
MINIMUM_DEFAULT_RUBY_VERSION="${MINIMUM_DEFAULT_RUBY_VERSION:-3.3.11}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$UPSTREAM_URL"
else
  git remote add upstream "$UPSTREAM_URL"
fi

latest_tag="$(
  git ls-remote --refs --tags upstream 'v*' \
    | awk -F/ '{print $NF}' \
    | sort -V \
    | tail -n 1
)"

if [[ -z "$latest_tag" ]]; then
  echo "Could not determine the latest upstream v* tag."
  exit 1
fi

branch_name="${latest_tag}-1"

if git ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1; then
  warning_message="Branch ${branch_name} already exists on origin. Skipping sync."
  echo "::warning::${warning_message}"
  echo "${warning_message}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## Sync Upstream"
      echo
      echo "- Warning: ${warning_message}"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "latest_tag=${latest_tag}"
    echo "branch_name=${branch_name}"
  } >> "$GITHUB_OUTPUT"
fi

git fetch --force upstream "refs/tags/${latest_tag}:refs/tags/${latest_tag}"

source_commit="$(git rev-parse "$SOURCE_REF")"
git checkout -B "$branch_name" "$source_commit"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
git archive "refs/tags/${latest_tag}" | tar -x -C "$tmpdir"
rsync -a --delete --exclude='.git' --exclude='.github' "$tmpdir"/ ./

git add -A
if git diff --cached --quiet; then
  echo "No content changes detected while syncing ${latest_tag} onto ${SOURCE_REF}."
else
  git commit -m "Sync upstream ${latest_tag} without workflow changes"
fi

default_ruby_version=""
if [[ -f buildpack.toml ]]; then
  default_ruby_version="$(
    awk '
      /^\[/ { in_buildpack = ($0 == "[buildpack]") }
      in_buildpack && $0 ~ /^[[:space:]]*ruby_version[[:space:]]*=/ {
        print
        exit
      }
    ' buildpack.toml | sed -E 's/^[^=]+=[[:space:]]*["'\'']?([^"'\''[:space:]]+).*/\1/'
  )"
fi

if [[ -z "$default_ruby_version" ]]; then
  echo "Could not determine buildpack.toml default Ruby version. Cherry-picking ${DEFAULT_RUBY_BUMP_COMMIT}."
  git cherry-pick "$DEFAULT_RUBY_BUMP_COMMIT"
elif [[ "$default_ruby_version" == "$MINIMUM_DEFAULT_RUBY_VERSION" ]]; then
  echo "buildpack.toml default Ruby version is ${default_ruby_version}; skipping ${DEFAULT_RUBY_BUMP_COMMIT}."
elif [[ "$(printf '%s\n%s\n' "$default_ruby_version" "$MINIMUM_DEFAULT_RUBY_VERSION" | sort -V | head -n 1)" == "$default_ruby_version" ]]; then
  echo "buildpack.toml default Ruby version ${default_ruby_version} is older than ${MINIMUM_DEFAULT_RUBY_VERSION}. Cherry-picking ${DEFAULT_RUBY_BUMP_COMMIT}."
  git cherry-pick "$DEFAULT_RUBY_BUMP_COMMIT"
else
  echo "buildpack.toml default Ruby version ${default_ruby_version} is newer than ${MINIMUM_DEFAULT_RUBY_VERSION}; skipping ${DEFAULT_RUBY_BUMP_COMMIT}."
fi

python3 <<'PY'
import re
import sys
from pathlib import Path


def replace(path: str, pattern: str, repl: str, *, description: str, flags: int = 0, count: int = 1) -> None:
    file_path = Path(path)
    if not file_path.exists():
        print(f"Missing expected patch target: {path}", file=sys.stderr)
        sys.exit(1)

    content = file_path.read_text()
    updated, replacements = re.subn(pattern, repl, content, count=count, flags=flags)
    if replacements != count:
        print(f"Could not apply patch for {description} in {path}.", file=sys.stderr)
        sys.exit(1)
    file_path.write_text(updated)


replace(
    "lib/language_pack.rb",
    r'(^\s*stack\s*=\s*)ENV\.fetch\("STACK"\)',
    r'\1ENV.fetch("STACK", "")',
    description="language pack STACK default",
    flags=re.MULTILINE,
)

replace(
    "lib/language_pack/base.rb",
    r'(^\s*@stack\s*=\s*)ENV\.fetch\("STACK"\)',
    r'\1ENV.fetch("STACK", "")',
    description="base STACK default",
    flags=re.MULTILINE,
)

replace(
    "lib/language_pack/base.rb",
    r'(^  def self\.get_arch\n)',
    "\\1    return \"amd64\" # packager currently only supports amd64\n",
    description="base arch default",
    flags=re.MULTILINE,
)

replace(
    "bin/compile",
    r'^checks::ensure_supported_stack "\$\{STACK:\?Required env var STACK is not set\}"$',
    '# checks::ensure_supported_stack "${STACK:?Required env var STACK is not set}"',
    description="compile STACK check bypass",
    flags=re.MULTILINE,
)

replace(
    "bin/support/download_ruby",
    r'^\s*heroku_buildpack_ruby_url=\$\(ruby_url "\$STACK" "\$\{BASH_REMATCH\[1\]\}"\)$',
    '    heroku_buildpack_ruby_url="${BUILDCURL_URL:="buildcurl.com"}?recipe=ruby&version=${BASH_REMATCH[1]}&target=$TARGET"',
    description="bootstrap ruby buildcurl URL",
    flags=re.MULTILINE,
)

replace(
    "lib/language_pack/fetcher.rb",
    r'(?ms)^    def curl_command\(command\)\n.*?^    def curl_timeout_in_seconds\n',
    """    def curl_command(command)\n"""
    """      binary, *rest = command.split(" ")\n"""
    """      buildcurl_mapping = {\n"""
    """        "ruby" => /^ruby-(.+)$/,\n"""
    """        "rubygem-bundler" => /^bundler-(.+)$/,\n"""
    """        "libyaml" => /^libyaml-(.+)$/,\n"""
    """        "node" => /^node-v(.+)-linux.+$/,\n"""
    """      }\n"""
    """      buildcurl_mapping.each do |k,v|\n"""
    """        if File.basename(binary, ".tgz") =~ v || File.basename(binary, ".tar.gz") =~ v\n"""
    """          return "set -o pipefail; curl -L --get --fail --retry 3 #{buildcurl_url} -d recipe=#{k} -d version=#{$1} -d target=$TARGET #{rest.join(" ")}"\n"""
    """        end\n"""
    """      end\n"""
    """      "set -o pipefail; curl -L --fail --retry 3 --retry-delay 1 --connect-timeout #{curl_connect_timeout_in_seconds} --max-time #{curl_timeout_in_seconds} #{command}"\n"""
    """    end\n"""
    """\n"""
    """    def buildcurl_url\n"""
    """      ENV['BUILDCURL_URL'] || "buildcurl.com"\n"""
    """    end\n"""
    """\n"""
    """    def curl_timeout_in_seconds\n""",
    description="fetcher buildcurl routing",
)

replace(
    "lib/language_pack/helpers/node_installer.rb",
    r'(^\s*node_bin = "\#\{binary_path\}/bin/node"\n)',
    '\\1      # buildcurl has no path prefix, so overwriting. Can\\\'t override binary_path since it seems to be used elsewhere\n      node_bin = "./bin/node"\n',
    description="node installer buildcurl extraction path",
    flags=re.MULTILINE,
)

replace(
    "lib/language_pack/helpers/nodebin.rb",
    r'(?ms)^  def self\.hardcoded_node_lts\(.*?^  end\n',
    """  def self.hardcoded_node_lts(arch: )\n"""
    """    version = case ENV.fetch("TARGET")\n"""
    """    when "ubuntu:18.04", "ubuntu:16.04", "el:7", "sles:12"\n"""
    """      "16.18.1"\n"""
    """    else\n"""
    """      NODE_VERSION\n"""
    """    end\n"""
    """    arch = "x64" if arch == "amd64"\n"""
    """    {\n"""
    """      "number" => version,\n"""
    """      "url"    => "https://nodejs.org/dist/v#{version}/node-v#{version}-linux-#{arch}.tar.gz"\n"""
    """    }\n"""
    """  end\n""",
    description="nodebin buildcurl URL handling",
)

replace(
    "lib/language_pack/ruby.rb",
    r'(^  def warn_stack_upgrade\n)',
    "\\1    return\n",
    description="disable stack upgrade warning",
    flags=re.MULTILINE,
)

replace(
    "lib/language_pack/helpers/plugin_installer.rb",
    r'--retry 3 --retry-connrefused --connect-timeout',
    '--retry 3 --connect-timeout',
    description="plugin installer curl flags",
)
PY

git add \
  bin/compile \
  bin/support/download_ruby \
  lib/language_pack.rb \
  lib/language_pack/base.rb \
  lib/language_pack/fetcher.rb \
  lib/language_pack/helpers/node_installer.rb \
  lib/language_pack/helpers/nodebin.rb \
  lib/language_pack/helpers/plugin_installer.rb \
  lib/language_pack/ruby.rb

if git diff --cached --quiet; then
  echo "No buildcurl compatibility patches were applied."
  exit 1
fi

git commit -m "Apply buildcurl compatibility patches"

if [[ "$PUSH_CHANGES" == "1" ]]; then
  git push origin "HEAD:refs/heads/${branch_name}"
else
  echo "Skipping push because PUSH_CHANGES=${PUSH_CHANGES}."
fi
