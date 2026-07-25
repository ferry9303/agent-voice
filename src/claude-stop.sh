#!/usr/bin/env bash
# Claude Code 的 Stop hook：回复结束时朗读一句摘要。
# 挂载：~/.claude/settings.json → hooks.Stop[].hooks[].command
#
# hook 必须立刻返回，但「等最终回复落盘」需要轮询几秒，
# 所以先把自己重新拉起到后台，再在后台做全部实际工作。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${TMPDIR:-/tmp}/agent-voice"

[[ -n "${AGENT_VOICE_CHILD:-}" ]] && exit 0
# shellcheck disable=SC1090
CONFIG="${AGENT_VOICE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice/config.env}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"
[[ "${AGENT_VOICE:-1}" == "0" ]] && exit 0
WAIT_FOR_REPLY="${AGENT_VOICE_WAIT:-6}"

payload="$(cat)"
[[ -z "${payload//[[:space:]]/}" ]] && exit 0

# 第一次进来：丢到后台立刻返回，别卡住 Claude Code
if [[ "${AGENT_VOICE_WORKER:-}" != "1" ]]; then
  ( AGENT_VOICE_WORKER=1 nohup "$0" >/dev/null 2>&1 <<<"$payload" & ) &
  exit 0
fi

read -r transcript session <<<"$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit
print(d.get("transcript_path", ""), d.get("session_id", "default"))
' 2>/dev/null)"
[[ -f "$transcript" ]] || exit 0

mkdir -p "$STATE_DIR"
reply="$(python3 "$HERE/extract-reply.py" \
  --state "$STATE_DIR/claude-${session:-default}.uuid" \
  --wait "$WAIT_FOR_REPLY" \
  "$transcript" 2>/dev/null)"
[[ -z "${reply//[[:space:]]/}" ]] && exit 0

printf '%s' "$reply" | "$HERE/speak.sh"
