#!/usr/bin/env bash
# upstream-pr / create.sh — create upstream Issue then fork->upstream PR.
# Must only be run AFTER the skill's AskUserQuestion confirmation gate.
#
#   create.sh --issue-title T --issue-body F --pr-title T --pr-body F --branch B \
#             [--issue-label L] [--only-issue]
#
# Prints a JSON line: {"issue":N,"pr":N,"issue_url":"...","pr_url":"..."}.
# On failure prints the raw gh error to stderr and exits non-zero.
set -uo pipefail

CFG="${PR_WATCH_DIR:-$HOME/.upstream-pr-watch}/config"
[ -f "$CFG" ] && . "$CFG"
: "${UPSTREAM:?UPSTREAM 未配置(见 ~/.upstream-pr-watch/config)}"
: "${FORK_OWNER:?FORK_OWNER 未配置(见 ~/.upstream-pr-watch/config)}"

ITITLE="" IBODY="" PTITLE="" PBODY="" BRANCH="" LABEL="" ONLY_ISSUE=0
while [ $# -gt 0 ]; do case "$1" in
  --issue-title) ITITLE="$2"; shift 2;;
  --issue-body)  IBODY="$2";  shift 2;;
  --pr-title)    PTITLE="$2"; shift 2;;
  --pr-body)     PBODY="$2";  shift 2;;
  --branch)      BRANCH="$2"; shift 2;;
  --issue-label) LABEL="$2";  shift 2;;
  --only-issue)  ONLY_ISSUE=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$ITITLE" ] && [ -f "$IBODY" ] || { echo "missing --issue-title/--issue-body" >&2; exit 2; }

# --- issue ---
labelarg=(); [ -n "$LABEL" ] && labelarg=(--label "$LABEL")
issue_url=$(gh issue create --repo "$UPSTREAM" --title "$ITITLE" --body-file "$IBODY" "${labelarg[@]}") || {
  echo "gh issue create failed (see error above)" >&2; exit 1; }
issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')
echo "issue created: #$issue_num $issue_url" >&2

if [ "$ONLY_ISSUE" -eq 1 ]; then
  jq -nc --argjson i "$issue_num" --arg iu "$issue_url" '{issue:$i,issue_url:$iu}'
  exit 0
fi

[ -n "$PTITLE" ] && [ -f "$PBODY" ] && [ -n "$BRANCH" ] || { echo "missing --pr-title/--pr-body/--branch" >&2; exit 2; }

# inject "Fixes #N" if not already present
grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?) #${issue_num}\b" "$PBODY" || \
  printf '\n\nFixes #%s\n' "$issue_num" >> "$PBODY"

pr_url=$(gh pr create --repo "$UPSTREAM" --base main \
  --head "${FORK_OWNER}:${BRANCH}" --title "$PTITLE" --body-file "$PBODY") || {
  echo "gh pr create failed. 兜底手动 compare URL:" >&2
  echo "https://github.com/$UPSTREAM/compare/main...${FORK_OWNER}:$(echo "$UPSTREAM" | cut -d/ -f2):${BRANCH}?expand=1" >&2
  exit 1; }
pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
echo "pr created: #$pr_num $pr_url" >&2

jq -nc --argjson i "$issue_num" --argjson p "$pr_num" --arg iu "$issue_url" --arg pu "$pr_url" \
  '{issue:$i,pr:$p,issue_url:$iu,pr_url:$pu}'
