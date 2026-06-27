#!/usr/bin/env bash
# upstream-pr / watchctl.sh — manage PR watcher daemons.
#
#   watchctl.sh list
#   watchctl.sh status <pr>
#   watchctl.sh stop <pr>
#   watchctl.sh stop-all
#   watchctl.sh cleanup
set -uo pipefail

CFG="${OCTO_PR_WATCH_DIR:-$HOME/.octo-pr-watch}/config"
[ -f "$CFG" ] && . "$CFG"
BASE_DIR="${OCTO_PR_WATCH_DIR:-$HOME/.octo-pr-watch}"

alive() { local p; p=$(cat "$1/watcher.pid" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

cmd="${1:-list}"; arg="${2:-}"

find_dir() { # by pr number, match *__<pr>
  local d; for d in "$BASE_DIR"/*__"$1"; do [ -d "$d" ] && { echo "$d"; return 0; }; done; return 1
}

case "$cmd" in
  list)
    printf "%-44s %-8s %-8s %s\n" "PR" "PID" "ALIVE" "STATE"
    shopt -s nullglob
    for d in "$BASE_DIR"/*__*; do
      [ -d "$d" ] || continue
      pid=$(cat "$d/watcher.pid" 2>/dev/null || echo "-")
      al=no; alive "$d" && al=yes
      st=$(jq -r '.pr_state // "?"' "$d/state.json" 2>/dev/null)
      printf "%-44s %-8s %-8s %s\n" "$(basename "$d")" "$pid" "$al" "$st"
    done
    ;;
  status)
    [ -n "$arg" ] || { echo "usage: watchctl.sh status <pr>"; exit 2; }
    d=$(find_dir "$arg") || { echo "no watcher for PR $arg"; exit 1; }
    echo "dir   : $d"
    echo "pid   : $(cat "$d/watcher.pid" 2>/dev/null || echo -)  alive=$(alive "$d" && echo yes || echo no)"
    echo "state : $(jq -c . "$d/state.json" 2>/dev/null)"
    echo "--- last log ---"; tail -n 15 "$d/watcher.log" 2>/dev/null
    ;;
  stop)
    [ -n "$arg" ] || { echo "usage: watchctl.sh stop <pr>"; exit 2; }
    d=$(find_dir "$arg") || { echo "no watcher for PR $arg"; exit 1; }
    p=$(cat "$d/watcher.pid" 2>/dev/null || echo "")
    [ -n "$p" ] && kill "$p" 2>/dev/null && echo "stopped pid $p" || echo "no live pid"
    rm -f "$d/watcher.pid"
    ;;
  stop-all)
    shopt -s nullglob
    for d in "$BASE_DIR"/*__*; do
      p=$(cat "$d/watcher.pid" 2>/dev/null || echo "")
      [ -n "$p" ] && kill "$p" 2>/dev/null && echo "stopped $(basename "$d") pid $p"
      rm -f "$d/watcher.pid"
    done
    ;;
  cleanup)
    shopt -s nullglob
    for d in "$BASE_DIR"/*__*; do
      if ! alive "$d"; then rm -f "$d/watcher.pid"; echo "cleaned dead pid: $(basename "$d")"; fi
    done
    ;;
  *) echo "usage: watchctl.sh {list|status <pr>|stop <pr>|stop-all|cleanup}"; exit 2;;
esac
