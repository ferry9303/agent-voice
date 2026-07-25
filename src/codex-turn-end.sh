#!/usr/bin/env bash
# Codex CLI 一轮结束时朗读一句摘要。同一个脚本挂哪边都行：
#   ~/.codex/hooks.json → hooks.Stop[]        （载荷走 stdin，需一次性信任授权）
#   ~/.codex/config.toml → notify = [本脚本]  （载荷走最后一个参数）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${AGENT_VOICE_HOME:-$HOME/.local/share/agent-voice}/run"

[[ -n "${AGENT_VOICE_CHILD:-}" ]] && exit 0
# shellcheck disable=SC1090
CONFIG="${AGENT_VOICE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice/config.env}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"
[[ "${AGENT_VOICE:-1}" == "0" ]] && exit 0

if [[ $# -ge 1 ]]; then
  payload="${!#}"
else
  payload="$(cat)"
fi
[[ -z "${payload//[[:space:]]/}" ]] && exit 0

mkdir -p "$STATE_DIR"
reply="$(printf '%s' "$payload" | python3 "$HERE/extract-codex-reply.py" \
  --state "$STATE_DIR/codex-last.sha1" 2>/dev/null)"
[[ -z "${reply//[[:space:]]/}" ]] && exit 0

( printf '%s' "$reply" | nohup "$HERE/speak.sh" >/dev/null 2>&1 & ) &
exit 0
