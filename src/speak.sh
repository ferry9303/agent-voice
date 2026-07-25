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
#   AGENT_VOICE_QUEUE         queue(默认,排队播完) | interrupt(新的打断旧的)
#   AGENT_VOICE_SAY_VOICE / _RATE say 的音色与语速（仅 say 引擎用）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 状态目录必须是所有会话共用的固定路径。放 TMPDIR 下不保险——
# 不同登录会话/SSH/launchd 的 TMPDIR 未必相同，锁就形同虚设。
STATE_DIR="${AGENT_VOICE_HOME:-$HOME/.local/share/agent-voice}/run"
SPOOL="$STATE_DIR/spool"
LOCK_DIR="$STATE_DIR/player.lock"
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
QUEUE_MODE="${AGENT_VOICE_QUEUE:-queue}"
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

mkdir -p "$SPOOL"

# 单播放者 + 排队：谁抢到锁谁当播放者，一条条播完队列里的内容；
# 抢不到的把文本丢进队列就走人，正在播的那个会接着取。
# 播放者可能被 kill（agent-voice stop），所以锁是目录 + owner pid，
# owner 进程没了就当僵尸锁清掉，不然一次异常退出会永久堵死播报。
acquire_lock() {
  local owner tries
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ >"$LOCK_DIR/owner"
      return 0
    fi
    # mkdir 成功到写进 owner 之间有个窗口，这期间 owner 是空的。
    # 读到空就当僵尸锁删掉的话，会把正要接管的那个进程的锁抢走，
    # 两边就同时播了。所以空 owner 要多等几次再判死。
    owner=""
    for tries in 1 2 3 4 5; do
      owner="$(cat "$LOCK_DIR/owner" 2>/dev/null)"
      [[ -n "$owner" ]] && break
      sleep 0.1
    done
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
      return 1                      # 确实有活着的播放者
    fi
    rm -rf "$LOCK_DIR"              # 僵尸锁，清掉重抢
  done
}

release_lock() { rm -rf "$LOCK_DIR"; }

play_and_wait() {
  "$@" &
  local pid=$!
  echo "$pid" >"$PID_FILE"
  wait "$pid" 2>/dev/null
  rm -f "$PID_FILE"
}

# —— Kokoro：本地神经 TTS，音质好，合成约 1.5s ——
speak_kokoro() {
  local text="$1" wav body
  wav="$STATE_DIR/out.$$.wav"
  body="$(python3 -c '
import json, sys
print(json.dumps({"text": sys.argv[1], "voice": sys.argv[2], "speed": float(sys.argv[3])}))
' "$text" "$KOKORO_VOICE" "$SPEED" 2>/dev/null)" || return 1
  [[ -z "$body" ]] && return 1
  curl -sf --max-time 30 -X POST "$KOKORO_URL/speak" \
    -H 'Content-Type: application/json' -d "$body" -o "$wav" || return 1
  [[ -s "$wav" ]] || { rm -f "$wav"; return 1; }
  # 模型自己的 speed 参数对 v1.1-zh 无效（实测 1.0~1.5 时长完全一样，
  # 低于 1.0 还会让 ONNX 整数溢出崩溃），只能合成完再变速。
  # sox tempo -s 是变速不变调，音高不会变尖。
  if [[ "$SPEED" != "1.0" && "$SPEED" != "1" ]] && command -v sox >/dev/null 2>&1; then
    if sox "$wav" "$wav.t" tempo -s "$SPEED" 2>/dev/null && [[ -s "$wav.t" ]]; then
      mv "$wav.t" "$wav"
    else
      rm -f "$wav.t"
    fi
  fi
  play_and_wait afplay "$wav"
  rm -f "$wav"
}

# —— say：系统自带，音色机械但零依赖，作为兜底 ——
speak_say() {
  local text="$1" spoken
  command -v say >/dev/null 2>&1 || return 1
  # say 支持 [[slnc N]] 嵌入停顿；压缩音色没有语气，
  # 靠标点处的呼吸感能减轻「一口气念完」的机械感。
  spoken="$(printf '%s' "$text" | sed \
    -e "s/\([。！？!?]\)/\1[[slnc ${PAUSE_SENTENCE}]]/g" \
    -e "s/\([，,；;：:、]\)/\1[[slnc ${PAUSE_CLAUSE}]]/g")"
  play_and_wait say -v "$VOICE" -r "$RATE" -- "$spoken"
}

speak_one() {
  case "$ENGINE" in
    kokoro) speak_kokoro "$1" ;;
    say)    speak_say "$1" ;;
    *)      speak_kokoro "$1" || speak_say "$1" ;;
  esac
}

# interrupt 模式：清空队列并掐掉正在播的，只保留最新一条
if [[ "$QUEUE_MODE" == "interrupt" ]]; then
  rm -f "$SPOOL"/*.txt 2>/dev/null
  [[ -f "$PID_FILE" ]] && kill "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
fi

# 入队。用纳秒时间戳当文件名，保证按到达顺序播。
printf '%s' "$line" >"$SPOOL/$(python3 -c 'import time;print(time.time_ns())').txt"

# 抢不到锁说明已经有播放者在跑，它会把刚入队的这条一起播掉
acquire_lock || exit 0
trap 'release_lock' EXIT INT TERM

while :; do
  next="$(find "$SPOOL" -name '*.txt' 2>/dev/null | sort | head -1)"
  if [[ -z "$next" ]]; then
    # 判空到释放锁之间也有窗口：别人可能刚好在这时入队然后抢锁失败，
    # 那条就没人播了。所以先放锁、再看一眼，有货就重新抢回来接着播。
    release_lock
    sleep 0.1
    next="$(find "$SPOOL" -name '*.txt' 2>/dev/null | sort | head -1)"
    [[ -z "$next" ]] && break
    acquire_lock || break
    continue
  fi
  text="$(cat "$next" 2>/dev/null)"
  rm -f "$next"
  [[ -z "${text//[[:space:]]/}" ]] && continue
  speak_one "$text"
done
