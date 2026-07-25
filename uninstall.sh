#!/usr/bin/env bash
# 卸载语音播报。默认保留模型和配置，加 --purge 一起删。
set -euo pipefail

LINK="${AGENT_VOICE_LINK:-$HOME/.local/share/agent-voice/bin}"
CONFIG_PATH="${AGENT_VOICE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice/config.env}"
APP_HOME="${AGENT_VOICE_HOME:-$HOME/.local/share/agent-voice}"
LABEL="com.agent-voice.kokoro-tts"
PURGE=""
[[ "${1:-}" == "--purge" ]] && PURGE=yes

say_ok() { printf '    \033[32m✓\033[0m %s\n' "$1"; }

echo "==> 停掉常驻服务"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
say_ok "已卸载 launchd agent"

echo "==> 摘掉 hook"
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
print(f"    \033[32m✓\033[0m 已从 {path.name} 摘除")
PY
done

echo "==> 移除软链"
[[ -L "$LINK" ]] && rm -f "$LINK" && say_ok "已删 $LINK"

if [[ -n "$PURGE" ]]; then
  echo "==> 清理模型与配置"
  rm -rf "$APP_HOME"; say_ok "已删 $APP_HOME"
  rm -f "$CONFIG_PATH"; say_ok "已删 ~/.config/agent-voice/config.env"
else
  echo
  echo "模型和配置保留在："
  echo "  $APP_HOME"
  echo "  $CONFIG_PATH"
  echo "要一并删除：./uninstall.sh --purge"
fi
