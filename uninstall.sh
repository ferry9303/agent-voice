#!/usr/bin/env bash
# 卸载 agent-voice。默认保留模型和配置，加 --purge 一起删。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib-ui.sh
source "$REPO/src/lib-ui.sh"

LINK="${AGENT_VOICE_LINK:-$HOME/.local/share/agent-voice/bin}"
CONFIG_PATH="${AGENT_VOICE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice/config.env}"
APP_HOME="${AGENT_VOICE_HOME:-$HOME/.local/share/agent-voice}"
BIN_DIR="$HOME/.local/bin"
LABEL="com.agent-voice.kokoro-tts"
PURGE=""
[[ "${1:-}" == "--purge" ]] && PURGE=yes

ui_step "停掉常驻服务"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
ui_ok "launchd agent 已卸载"

ui_step "摘掉 hook"
for target in "$HOME/.claude/settings.json:claude-stop.sh" \
              "$HOME/.codex/hooks.json:codex-turn-end.sh"; do
  python3 - "${target%%:*}" "${target##*:}" <<'PY'
import json, pathlib, sys
path, script = pathlib.Path(sys.argv[1]), sys.argv[2]
if not path.is_file():
    raise SystemExit
cfg = json.loads(path.read_text())
stop = cfg.get("hooks", {}).get("Stop", [])
kept = []
for entry in stop:
    hooks = [h for h in entry.get("hooks", []) if script not in (h.get("command") or "")]
    if hooks:
        kept.append({**entry, "hooks": hooks})
if kept:
    cfg["hooks"]["Stop"] = kept
else:
    cfg.get("hooks", {}).pop("Stop", None)
path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
print(path.name)
PY
done | while read -r name; do ui_ok "已从 $name 摘除"; done

ui_step "移除脚本与命令"
[[ -L "$LINK" ]] && rm -f "$LINK" && ui_ok "$LINK"
[[ -L "$BIN_DIR/agent-voice" ]] && rm -f "$BIN_DIR/agent-voice" && ui_ok "$BIN_DIR/agent-voice"
[[ -L "$HOME/.claude/commands/tts.md" ]] && rm -f "$HOME/.claude/commands/tts.md" \
  && ui_ok "~/.claude/commands/tts.md"

if [[ -n "$PURGE" ]]; then
  ui_step "清理模型与配置"
  rm -rf "$APP_HOME"; ui_ok "$APP_HOME"
  rm -f "$CONFIG_PATH"; ui_ok "$CONFIG_PATH"
  printf '\n已彻底卸载。\n\n'
else
  printf '\n模型和配置保留在：\n  %s\n  %s\n\n要一并删除：./uninstall.sh --purge\n\n' \
    "$APP_HOME" "$CONFIG_PATH"
fi
