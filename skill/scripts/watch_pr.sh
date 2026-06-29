#!/usr/bin/env bash
# upstream-pr / watch_pr.sh — poll a PR and push IM webhook notifications on
# request-changes reviews / approvals / merge / close, then self-terminate.
#
#   watch_pr.sh --pr N [--repo O/R] [--interval S] [--events ...] [--detach]
#
# --detach re-execs itself under setsid (daemon, survives the agent session).
# Notifications POST {"content":"<markdown>"} to a per-event webhook: an event
# listed in MENTION_ROUTES goes to its URL (a webhook the human pre-configured
# with mention_uids=[bot] so the post @s that bot and triggers it); every other
# event falls back to WEBHOOK_URL. We never craft the mention ourselves — the @
# target lives entirely in the destination webhook's server-side config.
set -uo pipefail

CFG="${PR_WATCH_DIR:-$HOME/.upstream-pr-watch}/config"
[ -f "$CFG" ] && . "$CFG"
: "${UPSTREAM:?UPSTREAM 未配置(见 ~/.upstream-pr-watch/config)}"
: "${POLL_INTERVAL:=90}"
: "${WATCH_EVENTS:=request_changes,approved,merged,closed}"
: "${MAX_AGE_DAYS:=14}"

REPO="$UPSTREAM" PR="" INTERVAL="$POLL_INTERVAL" EVENTS="$WATCH_EVENTS" DETACH=0
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2;;
  --pr) PR="$2"; shift 2;;
  --interval) INTERVAL="$2"; shift 2;;
  --events) EVENTS="$2"; shift 2;;
  --max-age-days) MAX_AGE_DAYS="$2"; shift 2;;
  --detach) DETACH=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$PR" ] || { echo "missing --pr" >&2; exit 2; }
: "${WEBHOOK_URL:?WEBHOOK_URL 未配置(见 ~/.upstream-pr-watch/config)}"

BASE_DIR="${PR_WATCH_DIR:-$HOME/.upstream-pr-watch}"
SLUG="$(echo "$REPO" | tr '/' '_')__${PR}"
STATE_DIR="$BASE_DIR/$SLUG"
mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/state.json"
PIDF="$STATE_DIR/watcher.pid"
LOG="$STATE_DIR/watcher.log"
PR_URL="https://github.com/$REPO/pull/$PR"

# idempotent: already running?
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
  echo "watcher already running for $REPO#$PR (pid $(cat "$PIDF"))"; exit 0
fi

# detach into a daemon, then return
if [ "$DETACH" -eq 1 ]; then
  setsid nohup "$0" --repo "$REPO" --pr "$PR" --interval "$INTERVAL" \
    --events "$EVENTS" --max-age-days "$MAX_AGE_DAYS" >>"$LOG" 2>&1 &
  sleep 1
  echo "watcher started: $REPO#$PR pid=$(cat "$PIDF" 2>/dev/null || echo '?') interval=${INTERVAL}s log=$LOG"
  exit 0
fi

echo "$$" > "$PIDF"
trap 'rm -f "$PIDF"' EXIT
[ -f "$STATE" ] || echo '{}' > "$STATE"

has_event() { case ",$EVENTS," in *",$1,"*) return 0;; *) return 1;; esac; }
state_get() { jq -r "$1 // empty" "$STATE" 2>/dev/null; }
state_set() { local t; t=$(jq "$1" "$STATE") && printf '%s' "$t" > "$STATE"; }

# route_webhook EVENT -> push URL. MENTION_ROUTES is a JSON map {event:url}; a
# matched event posts to that (bot-mentioning) webhook, else WEBHOOK_URL.
route_webhook() {
  local u=""
  [ -n "${MENTION_ROUTES:-}" ] && \
    u=$(printf '%s' "$MENTION_ROUTES" | jq -r --arg e "$1" '.[$e] // empty' 2>/dev/null)
  [ -n "$u" ] && printf '%s' "$u" || printf '%s' "$WEBHOOK_URL"
}

# mention_prompt EVENT -> optional instruction text for the triggered bot, read
# from env MENTION_PROMPT_<event> with {pr}/{url}/{title} substituted. Empty when
# unset, so non-routed/plain events append nothing.
mention_prompt() {
  local var="MENTION_PROMPT_${1}" tmpl
  tmpl="${!var:-}"
  [ -z "$tmpl" ] && return 0
  tmpl="${tmpl//\{pr\}/$PR}"; tmpl="${tmpl//\{url\}/$PR_URL}"; tmpl="${tmpl//\{title\}/${title:-}}"
  printf '%s' "$tmpl"
}

# notify EVENT MARKDOWN — pick the webhook by event, optionally append the bot
# instruction, POST {"content":...}. The @ comes from the webhook's own config.
notify() {
  local event="$1" md="$2" url p
  url=$(route_webhook "$event")
  p=$(mention_prompt "$event")
  [ -n "$p" ] && md="$md\n$p"
  # callers write "\n" as a literal escape for readability; turn it into a real
  # newline so the webhook JSON carries a true line break (IM renders markdown).
  md="${md//\\n/$'\n'}"
  curl -sS -m 20 -X POST "$url" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg c "$md" '{content:$c}')" >/dev/null \
    || echo "$(date -Is) notify FAILED (event=$event)" >&2
}

echo "$(date -Is) watcher up: $REPO#$PR interval=${INTERVAL}s events=$EVENTS"
START=$(date +%s)
FAILS=0
title=""   # set each loop after the PR fetch; init for set -u safety

while true; do
  # hard expiry
  if [ $(( ($(date +%s) - START) / 86400 )) -ge "$MAX_AGE_DAYS" ]; then
    notify expiry "🕒 PR [#$PR]($PR_URL) 监听已满 ${MAX_AGE_DAYS} 天,守护进程自动停止。"
    exit 0
  fi

  prjson=$(gh pr view "$PR" --repo "$REPO" --json state,title,reviewDecision 2>/dev/null)
  if [ -z "$prjson" ]; then
    FAILS=$((FAILS+1))
    if [ "$FAILS" -ge 5 ]; then
      notify error "⚠️ PR [#$PR]($PR_URL) 守护进程连续 $FAILS 次拉取失败(token 失效/网络?),已退出。"
      exit 1
    fi
    sleep $(( INTERVAL * (FAILS+1) )); continue
  fi
  FAILS=0
  state=$(echo "$prjson" | jq -r .state)
  title=$(echo "$prjson" | jq -r .title)

  reviews=$(gh api "repos/$REPO/pulls/$PR/reviews" --paginate 2>/dev/null || echo "[]")
  primed=$(state_get '.primed')

  if [ "$primed" != "true" ]; then
    # first run: seed seen ids, do NOT replay history
    allids=$(echo "$reviews" | jq -c '[.[].id]')
    state_set ".seen_review_ids = $allids | .primed = true | .pr_state = \"$state\""
    notify start "👀 开始监听 PR [#$PR]($PR_URL)\n> $title\n轮询 ${INTERVAL}s · 触发: $EVENTS"
  else
    seen=$(jq -c '.seen_review_ids // []' "$STATE")
    echo "$reviews" | jq -c --argjson seen "$seen" \
      '[.[] | select((.id as $i | ($seen|index($i))|not))] | .[]' 2>/dev/null | \
    while read -r r; do
      rstate=$(echo "$r" | jq -r .state)
      who=$(echo "$r" | jq -r '.user.login // "someone"')
      case "$rstate" in
        CHANGES_REQUESTED) has_event request_changes && \
          notify request_changes "🔴 **Request changes** — PR [#$PR]($PR_URL) by **$who**\n> $title" ;;
        APPROVED) has_event approved && \
          notify approved "✅ **Approved** — PR [#$PR]($PR_URL) by **$who**" ;;
      esac
    done
    allids=$(echo "$reviews" | jq -c '[.[].id]')
    state_set ".seen_review_ids = $allids"
  fi

  # terminal states -> notify + exit
  if [ "$state" = "MERGED" ] && has_event merged; then
    notify merged "🎉 PR [#$PR]($PR_URL) 已 **合并**。停止监听。"; exit 0
  elif [ "$state" = "CLOSED" ] && has_event closed; then
    notify closed "🚪 PR [#$PR]($PR_URL) 已 **关闭**(未合并)。停止监听。"; exit 0
  fi
  state_set ".pr_state = \"$state\""

  sleep "$INTERVAL"
done
