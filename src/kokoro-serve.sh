#!/usr/bin/env bash
# 启动常驻的 Kokoro TTS 服务。给 launchd 用，也可以手工跑来排查。
# 环境（venv + 模型）在 ~/.local/share/wincorp-tts，代码在本仓。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TTS_HOME="${WINCORP_TTS_HOME:-$HOME/.local/share/wincorp-tts}"
PYTHON="$TTS_HOME/.venv/bin/python"

[[ -x "$PYTHON" ]] || { echo "缺少 venv：$PYTHON" >&2; exit 1; }

export WINCORP_TTS_HOME="$TTS_HOME"
exec "$PYTHON" "$HERE/kokoro_server.py"
