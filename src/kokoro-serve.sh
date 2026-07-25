#!/usr/bin/env bash
# 启动常驻的 Kokoro TTS 服务。给 launchd 用，也可以手工跑来排查。
# 环境（venv + 模型）在 ~/.local/share/agent-voice，代码在本仓。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="${AGENT_VOICE_HOME:-$HOME/.local/share/agent-voice}"
CONFIG="${AGENT_VOICE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice/config.env}"
PYTHON="$APP_HOME/.venv/bin/python"

[[ -x "$PYTHON" ]] || { echo "缺少 venv：$PYTHON" >&2; exit 1; }

# launchd 不会读用户的 shell 环境，服务端要用的配置得在这里显式加载并导出，
# 否则改了 config.env 重启服务也不生效。
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"

export AGENT_VOICE_HOME="$APP_HOME"
export AGENT_VOICE_PORT="${AGENT_VOICE_PORT:-8127}"
export AGENT_VOICE_KOKORO_VOICE="${AGENT_VOICE_KOKORO_VOICE:-zf_017}"
export AGENT_VOICE_CHUNK="${AGENT_VOICE_CHUNK:-sentence}"
export AGENT_VOICE_PAUSE_SCALE="${AGENT_VOICE_PAUSE_SCALE:-1.0}"

exec "$PYTHON" "$HERE/kokoro_server.py"
