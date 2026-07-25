#!/usr/bin/env bash
# 朗读核心：stdin 收一段回复正文，压成一句后念出来。
# 由 claude-stop.sh / codex-turn-end.sh 在后台调用，本身是阻塞的。
#
# 开关与配置（可写进 ~/.config/agent-voice/config.env 持久化）：
#   AGENT_VOICE=0             关闭朗读
#   AGENT_VOICE_ENGINE        auto(默认) | kokoro | say
#   AGENT_VOICE_MODE=first    first=取回复首句(0 延迟) | llm=调 haiku 真摘要(约 10s)
#   AGENT_VOICE_MAX_CHARS     播报长度上限，默认 200
#   AGENT_VOICE_KOKORO_VOICE  Kokoro 音色，默认 zf_001
#   AGENT_VOICE_SPEED         Kokoro 语速倍率，默认 1.0
#   AGENT_VOICE_SAY_VOICE / _RATE say 的音色与语速（仅 say 引擎用）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${TMPDIR:-/tmp}/agent-voice"
PID_FILE="$STATE_DIR/player.pid"

# 递归护栏：llm 模式会再起一个 claude，它的 Stop hook 必须闭嘴
[[ -n "${AGENT_VOICE_CHILD:-}" ]] && exit 0

# shellcheck disable=SC1090
CONFIG="${AGENT_VOICE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice/config.env}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"

[[ "${AGENT_VOICE:-1}" == "0" ]] && exit 0

ENGINE="${AGENT_VOICE_ENGINE:-auto}"
MODE="${AGENT_VOICE_MODE:-first}"
KOKORO_URL="${AGENT_VOICE_KOKORO_URL:-http://127.0.0.1:8127}"
KOKORO_VOICE="${AGENT_VOICE_KOKORO_VOICE:-zf_001}"
SPEED="${AGENT_VOICE_SPEED:-1.0}"
VOICE="${AGENT_VOICE_SAY_VOICE:-Tingting}"
RATE="${AGENT_VOICE_SAY_RATE:-172}"
PAUSE_SENTENCE="${AGENT_VOICE_PAUSE_SENTENCE:-260}"
PAUSE_CLAUSE="${AGENT_VOICE_PAUSE_CLAUSE:-130}"

raw="$(cat)"
[[ -z "${raw//[[:space:]]/}" ]] && exit 0

summarize_with_llm() {
  local prompt
  prompt=$'把下面这段助手回复压成一句不超过25字的中文口语播报，只输出这句话，不要引号、不要任何解释：\n\n'"$raw"
  AGENT_VOICE_CHILD=1 timeout 25 claude -p --model haiku \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    <<<"$prompt" 2>/dev/null | tr -d '\r' | head -1
}

line=""
if [[ "$MODE" == "llm" ]]; then
  line="$(summarize_with_llm)"
fi
# first 模式，或 llm 调用失败/超时时回退
if [[ -z "${line//[[:space:]]/}" ]]; then
  line="$(printf '%s' "$raw" | python3 "$HERE/summarize.py" 2>/dev/null)"
fi
[[ -z "${line//[[:space:]]/}" ]] && exit 0

# 新播报打断旧播报，避免连着说话时叠音
mkdir -p "$STATE_DIR"
if [[ -f "$PID_FILE" ]]; then
  old="$(cat "$PID_FILE" 2>/dev/null)"
  [[ -n "$old" ]] && kill "$old" 2>/dev/null
fi

play_and_wait() {
  "$@" &
  local pid=$!
  echo "$pid" >"$PID_FILE"
  wait "$pid" 2>/dev/null
  rm -f "$PID_FILE"
}

# —— Kokoro：本地神经 TTS，音质好，合成约 1.5s ——
speak_kokoro() {
  local wav body
  wav="$STATE_DIR/out.$$.wav"
  body="$(python3 -c '
import json, sys
print(json.dumps({"text": sys.argv[1], "voice": sys.argv[2], "speed": float(sys.argv[3])}))
' "$line" "$KOKORO_VOICE" "$SPEED" 2>/dev/null)" || return 1
  [[ -z "$body" ]] && return 1
  curl -sf --max-time 30 -X POST "$KOKORO_URL/speak" \
    -H 'Content-Type: application/json' -d "$body" -o "$wav" || return 1
  [[ -s "$wav" ]] || { rm -f "$wav"; return 1; }
  play_and_wait afplay "$wav"
  rm -f "$wav"
}

# —— say：系统自带，音色机械但零依赖，作为兜底 ——
speak_say() {
  command -v say >/dev/null 2>&1 || return 1
  # say 支持 [[slnc N]] 嵌入停顿；压缩音色没有语气，
  # 靠标点处的呼吸感能减轻「一口气念完」的机械感。
  local spoken
  spoken="$(printf '%s' "$line" | sed \
    -e "s/\([。！？!?]\)/\1[[slnc ${PAUSE_SENTENCE}]]/g" \
    -e "s/\([，,；;：:、]\)/\1[[slnc ${PAUSE_CLAUSE}]]/g")"
  play_and_wait say -v "$VOICE" -r "$RATE" -- "$spoken"
}

case "$ENGINE" in
  kokoro) speak_kokoro ;;
  say)    speak_say ;;
  *)      speak_kokoro || speak_say ;;
esac
