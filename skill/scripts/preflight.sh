#!/usr/bin/env bash
# upstream-pr / preflight.sh — pre-create checks. Read-only except a transient
# fetch. Prints a human summary + exits non-zero on any blocker.
#
#   preflight.sh <worktree_dir> <branch>
set -uo pipefail

CFG="${OCTO_PR_WATCH_DIR:-$HOME/.octo-pr-watch}/config"
[ -f "$CFG" ] && . "$CFG"
: "${UPSTREAM:?UPSTREAM 未配置(见 ~/.octo-pr-watch/config)}"
: "${FORK_OWNER:?FORK_OWNER 未配置(见 ~/.octo-pr-watch/config)}"

WT="${1:?usage: preflight.sh <worktree_dir> <branch>}"
BRANCH="${2:?usage: preflight.sh <worktree_dir> <branch>}"
rc=0

echo "== upstream-pr preflight =="
echo "upstream : $UPSTREAM"
echo "fork     : $FORK_OWNER"
echo "branch   : $BRANCH"
echo "worktree : $WT"
echo

# 1) token + scope (never print the token itself)
if [ -z "${GH_TOKEN:-}" ]; then
  echo "FAIL token : GH_TOKEN 未设置(source ~/.bashrc 或导出)"; rc=1
else
  scopes=$(gh api -i user 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')
  login=$(gh api user --jq .login 2>/dev/null)
  if echo "$scopes" | grep -qiE '(^|, )(repo|public_repo)( |,|$)'; then
    echo "OK   token : $login, scopes=[$scopes]"
  else
    echo "FAIL token : $login scope 不含 repo/public_repo,无法提 upstream(scopes=[$scopes])"; rc=1
  fi
fi

# 2) branch present + pushed to fork
if ! git -C "$WT" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  echo "FAIL branch: 本地无分支 $BRANCH"; rc=1
else
  git -C "$WT" fetch -q origin "$BRANCH" 2>/dev/null || true
  local_sha=$(git -C "$WT" rev-parse "$BRANCH" 2>/dev/null)
  remote_sha=$(git -C "$WT" rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
  if [ -z "$remote_sha" ]; then
    echo "WARN branch: origin/$BRANCH 不存在,创建 PR 前需先 push 到 fork"
  elif [ "$local_sha" != "$remote_sha" ]; then
    echo "WARN branch: 本地与 origin/$BRANCH 不一致(local=$local_sha remote=$remote_sha),建议先 push"
  else
    echo "OK   branch: 已 push 到 fork($remote_sha)"
  fi
fi

# 3) conflict probe vs upstream/main (non-mutating)
if git -C "$WT" remote get-url upstream >/dev/null 2>&1; then
  git -C "$WT" fetch -q upstream main 2>/dev/null || true
  base=$(git -C "$WT" merge-base "$BRANCH" upstream/main 2>/dev/null || echo "")
  if [ -n "$base" ]; then
    if git -C "$WT" merge-tree "$base" "$BRANCH" upstream/main 2>/dev/null | grep -q '^<<<<<<<\|^changed in both'; then
      echo "FAIL merge : 与 upstream/main 存在冲突,先 rebase 解冲突再提"; rc=1
    else
      echo "OK   merge : 与 upstream/main 无冲突(merge-tree clean)"
    fi
  else
    echo "WARN merge : 找不到与 upstream/main 的 merge-base,跳过冲突探测"
  fi
else
  echo "WARN merge : worktree 无 upstream remote,跳过冲突探测"
fi

echo
[ "$rc" -eq 0 ] && echo "PREFLIGHT: PASS" || echo "PREFLIGHT: FAIL"
exit "$rc"
