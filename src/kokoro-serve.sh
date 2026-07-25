#!/usr/bin/env bash
# 启动常驻的 Kokoro TTS 服务。给 launchd 用，也可以手工跑来排查。
# 环境（venv + 模型）在 ~/.local/share/agent-voice，代码在本仓。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="${AGENT_VOICE_HOME:-$HOME/.local/share/agent-voice}"
PYTHON="$APP_HOME/.venv/bin/python"

[[ -x "$PYTHON" ]] || { echo "缺少 venv：$PYTHON" >&2; exit 1; }

export AGENT_VOICE_HOME="$APP_HOME"
exec "$PYTHON" "$HERE/kokoro_server.py"
