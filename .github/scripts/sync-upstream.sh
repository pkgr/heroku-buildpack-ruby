#!/usr/bin/env bash

set -euo pipefail

CHERRY_PICK_COMMIT="${CHERRY_PICK_COMMIT:-cfffff57adcc81587497e069c2107d594788b2b3}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/heroku/heroku-buildpack-ruby.git}"
PUSH_CHANGES="${PUSH_CHANGES:-1}"
SOURCE_REF="${SOURCE_REF:-HEAD}"

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
  echo "Branch ${branch_name} already exists on origin."
  exit 1
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

if [[ -f lib/language_pack.rb ]]; then
  python3 <<'PY'
import re
import sys
from pathlib import Path

path = Path("lib/language_pack.rb")
content = path.read_text()
content, replacements = re.subn(
    r'(^\s*stack\s*=\s*)ENV\.fetch\("STACK"\)',
    r'\1ENV.fetch("STACK", "")',
    content,
    count=1,
    flags=re.MULTILINE,
)
if replacements != 1:
    print('Could not update STACK default in lib/language_pack.rb.', file=sys.stderr)
    sys.exit(1)
path.write_text(content)
PY
fi

git add -A
if git diff --cached --quiet; then
  echo "No content changes detected while syncing ${latest_tag} onto ${SOURCE_REF}."
else
  git commit -m "Sync upstream ${latest_tag} without workflow changes"
fi

if git cherry-pick "$CHERRY_PICK_COMMIT"; then
  echo "Cherry-pick applied cleanly."
else
  conflicted_files="$(git diff --name-only --diff-filter=U | sort)"
  expected_conflicts=$'lib/language_pack/base.rb\nlib/language_pack/helpers/nodebin.rb'

  if [[ "$conflicted_files" != "$expected_conflicts" ]]; then
    echo "Unexpected conflict set:"
    printf '%s\n' "$conflicted_files"
    exit 1
  fi

  python3 <<'PY'
import re
import subprocess
import sys
from pathlib import Path


def read_ours(path: str) -> str:
    return subprocess.check_output(
        ["git", "show", f":2:{path}"],
        text=True,
    )


def write_file(path: str, content: str) -> None:
    Path(path).write_text(content)


base_path = "lib/language_pack/base.rb"
base_content = read_ours(base_path)
base_content, replacements = re.subn(
    r'(^\s*@stack\s*=\s*)ENV\.fetch\("STACK"\)',
    r'\1ENV.fetch("STACK", "")',
    base_content,
    count=1,
    flags=re.MULTILINE,
)
if replacements != 1:
    print(f"Could not resolve expected conflict in {base_path}.", file=sys.stderr)
    sys.exit(1)
write_file(base_path, base_content)

nodebin_path = "lib/language_pack/helpers/nodebin.rb"
nodebin_content = read_ours(nodebin_path)
nodebin_content, replacements = re.subn(
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
    nodebin_content,
    count=1,
)
if replacements != 1:
    print(f"Could not resolve expected conflict in {nodebin_path}.", file=sys.stderr)
    sys.exit(1)
write_file(nodebin_path, nodebin_content)
PY

  git add lib/language_pack/base.rb lib/language_pack/helpers/nodebin.rb
  git cherry-pick --continue
fi

if [[ "$PUSH_CHANGES" == "1" ]]; then
  git push origin "HEAD:refs/heads/${branch_name}"
else
  echo "Skipping push because PUSH_CHANGES=${PUSH_CHANGES}."
fi
