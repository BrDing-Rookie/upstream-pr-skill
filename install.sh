#!/usr/bin/env bash
# 安装 upstream-pr skill:把 skill/ 复制到 ~/.claude/skills/upstream-pr/,
# 并在 ~/.octo-pr-watch/config 不存在时从 config.example 初始化(不覆盖已有)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKILL_DST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/upstream-pr"
mkdir -p "$SKILL_DST/scripts"
cp "$HERE/skill/SKILL.md" "$SKILL_DST/SKILL.md"
cp "$HERE/skill/scripts/"*.sh "$SKILL_DST/scripts/"
chmod +x "$SKILL_DST/scripts/"*.sh
echo "skill 安装到 $SKILL_DST"

CFG_DIR="${OCTO_PR_WATCH_DIR:-$HOME/.octo-pr-watch}"
mkdir -p "$CFG_DIR"
if [ -f "$CFG_DIR/config" ]; then
  echo "config 已存在,保留不动:$CFG_DIR/config"
else
  cp "$HERE/config.example" "$CFG_DIR/config"
  chmod 600 "$CFG_DIR/config"
  echo "已从 config.example 初始化:$CFG_DIR/config —— 请填入真实 webhook/UPSTREAM/FORK_OWNER"
fi
echo "完成。用 GH_TOKEN(classic PAT,repo scope)后即可 /upstream-pr。"
