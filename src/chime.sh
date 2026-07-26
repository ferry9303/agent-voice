#!/usr/bin/env bash
# 提示音模式：一轮结束只「叮」一声，不念内容。
# 由 claude-stop.sh / codex-turn-end.sh 在 AGENT_VOICE_STYLE=chime 时调用，
# 也可以直接跑来试听。stdin 上的正文一律忽略。
#
#   AGENT_VOICE_CHIME_SOUND   系统音名（见 /System/Library/Sounds）或音频文件绝对路径，默认 Glass
#   AGENT_VOICE_CHIME_VOLUME  音量倍率，1 为原始，默认 1
set -uo pipefail

SYSTEM_SOUNDS="/System/Library/Sounds"

# shellcheck disable=SC1090
CONFIG="${AGENT_VOICE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice/config.env}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"

[[ "${AGENT_VOICE:-1}" == "0" ]] && exit 0

# 名字 → 路径。带 / 的当成文件路径直接用，否则去系统音里找同名 .aiff
chime_path() {
  local want="$1"
  if [[ "$want" == */* ]]; then
    printf '%s' "$want"
  else
    printf '%s/%s.aiff' "$SYSTEM_SOUNDS" "$want"
  fi
}

SOUND="$(chime_path "${1:-${AGENT_VOICE_CHIME_SOUND:-Glass}}")"
VOLUME="${AGENT_VOICE_CHIME_VOLUME:-1}"

# 配错名字也得有声，退回系统默认提示音，别静默失败
[[ -r "$SOUND" ]] || SOUND="$SYSTEM_SOUNDS/Glass.aiff"
[[ -r "$SOUND" ]] || exit 0

exec afplay -v "$VOLUME" "$SOUND"
