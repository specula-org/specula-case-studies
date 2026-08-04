#!/usr/bin/env bash
set -euo pipefail

repo_root="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/CR-4/worktree"

echo "CR-4 known-status prefilter evidence"
echo "repo_head=$(git -C "$repo_root" rev-parse HEAD)"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 2
fi

for pr in 1540 1363 1368; do
  json="$(curl -fsSL "https://api.github.com/repos/apache/ratis/pulls/${pr}")"
  title="$(jq -r '.title' <<<"$json")"
  state="$(jq -r '.state' <<<"$json")"
  merged="$(jq -r '.merged' <<<"$json")"
  url="$(jq -r '.html_url' <<<"$json")"
  echo "pr=${pr} state=${state} merged=${merged} title=${title}"
  echo "url=${url}"
  if [[ "$state" != "open" || "$merged" != "false" ]]; then
    echo "Unexpected fix status for PR ${pr}"
    exit 1
  fi
done

echo "DROPPED_PREFILTER_CONFIRMED: Code Review x known, fix-status=unfixed"
