#!/usr/bin/env bash
# 试听：把同一句话用不同 Kokoro 音色念一遍，方便挑。
# 用法:
#   ./audition.sh                    # 试听默认候选音色
#   ./audition.sh "自定义句子"
#   ./audition.sh -l                 # 列出全部可用音色
#   ./audition.sh -v zf_003,zm_010   # 只试听指定音色
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${AGENT_VOICE_KOKORO_URL:-http://127.0.0.1:8127}"
APP_HOME="${AGENT_VOICE_HOME:-$HOME/.local/share/agent-voice}"

# 候选：女声/男声各挑几个，覆盖不同音区
VOICES="zf_001,zf_017,zf_021,zf_032,zm_009,zm_020,zm_035"
LINE="语音播报已经接上了，回复结束时会自动念一句摘要给你听，比如 Claude Code 改了 3 个文件。"

while getopts ":lv:" opt; do
  case "$opt" in
    l)
      "$APP_HOME/.venv/bin/python" -c "
from kokoro_onnx import Kokoro
k = Kokoro('$APP_HOME/models/kokoro-v1.1-zh.onnx', '$APP_HOME/models/voices-v1.1-zh.bin')
v = k.get_voices()
print(f'共 {len(v)} 个音色：')
for i in range(0, len(v), 8):
    print('  ' + '  '.join(v[i:i + 8]))
" 2>/dev/null
      exit 0
      ;;
    v) VOICES="$OPTARG" ;;
    *) ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -ge 1 ]] && LINE="$1"

curl -sf --max-time 3 "$URL/health" >/dev/null || {
  echo "Kokoro 服务没起来。查看：launchctl print gui/\$(id -u)/com.ferry.kokoro-tts" >&2
  exit 1
}

echo "试听句：$LINE"
echo
IFS=',' read -r -a list <<<"$VOICES"
for voice in "${list[@]}"; do
  wav="${TMPDIR:-/tmp}/audition-$voice.wav"
  body="$(python3 -c '
import json, sys
print(json.dumps({"text": sys.argv[1], "voice": sys.argv[2]}))
' "$LINE" "$voice")"
  if curl -sf --max-time 30 -X POST "$URL/speak" \
       -H 'Content-Type: application/json' -d "$body" -o "$wav" && [[ -s "$wav" ]]; then
    echo "▶ $voice"
    afplay "$wav"
    rm -f "$wav"
  else
    echo "✗ ${voice}（合成失败）"
  fi
done

echo
echo "选定后写进 ~/.config/agent-voice/config.env："
echo "  AGENT_VOICE_KOKORO_VOICE=zf_017"
