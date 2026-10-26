#!/usr/bin/env bash
# What a release brings: the pull requests merged (and commits pushed
# straight to the branch) since the previous release of the same kind, as
# Markdown on stdout.
#
#   tool/release-notes.sh <sha> <prefix>
#
# <prefix> picks the previous release to compare against: "build-" for the
# automatic builds, "v" for tagged releases. Needs gh and GH_REPO.
set -euo pipefail

sha=$1
prefix=$2
repo=${GH_REPO:?GH_REPO must be set}
server=${GITHUB_SERVER_URL:-https://github.com}

# The newest published release of this kind that isn't this commit.
prev=$(gh api "repos/$repo/releases?per_page=100" --jq \
  "[.[] | select(.draft | not) | select(.tag_name | startswith(\"$prefix\"))
        | select(.target_commitish != \"$sha\")] | sort_by(.created_at) | last
   | if . == null then \"\" else \"\(.tag_name) \(.target_commitish)\" end")
prev_tag=${prev%% *}
prev_sha=${prev#* }

echo "## What's changed"
echo

if [ -z "$prev" ]; then
  echo "- First release."
  exit 0
fi

# Resolve a target that is a branch name rather than a commit.
if ! [[ "$prev_sha" =~ ^[0-9a-f]{40}$ ]]; then
  prev_sha=$(gh api "repos/$repo/commits/$prev_sha" --jq .sha)
fi

commits=$(gh api "repos/$repo/compare/$prev_sha...$sha" --jq '.commits[].sha')
if [ -z "$commits" ]; then
  echo "- No code changes since [$prev_tag]($server/$repo/releases/tag/$prev_tag) (rebuilt)."
  exit 0
fi

declare -A seen_pr=()
prs=()
direct=()
for c in $commits; do
  numbers=$(gh api "repos/$repo/commits/$c/pulls" --jq \
    '.[] | select(.merged_at != null) | select(.base.ref == "main") | .number' 2>/dev/null || true)
  if [ -n "$numbers" ]; then
    for n in $numbers; do
      if [ -z "${seen_pr[$n]:-}" ]; then
        seen_pr[$n]=1
        prs+=("$n")
      fi
    done
    continue
  fi
  subject=$(gh api "repos/$repo/commits/$c" --jq '.commit.message | split("\n")[0]')
  # Merge commits of pull requests are covered by the pull request itself.
  [[ "$subject" == "Merge pull request #"* ]] && continue
  [[ "$subject" == "Merge branch "* ]] && continue
  direct+=("- $subject (${c::7})")
done

# Newest first.
for n in $(printf '%s\n' "${prs[@]}" | sort -n -r); do
  gh api "repos/$repo/pulls/$n" --jq '"- \(.title) ([#\(.number)](\(.html_url)))"'
  # The pull request's own summary: its first paragraph, quoted, so the
  # release says what changed for the user and not just a title.
  summary=$(gh api "repos/$repo/pulls/$n" --jq '.body // ""' \
    | tr -d '\r' | awk 'NF==0{if(started)exit; next} /^#|^🤖|^https:\/\/claude\.ai/{exit} {started=1; print}')
  if [ -n "$summary" ]; then
    printf '%s\n' "$summary" | sed 's/^/  > /'
  fi
done
for line in "${direct[@]}"; do
  echo "$line"
done

echo
echo "**Full diff**: [$prev_tag...${sha::7}]($server/$repo/compare/$prev_sha...$sha)"
