#!/usr/bin/env bash
# 安装 agent-voice：让 Claude Code / Codex CLI 把回复念出来。
#
#   ./install.sh                 探测环境 → 给出计划 → 确认后安装
#   ./install.sh -y              不问，按默认全装
#   ./install.sh --no-kokoro     不装神经 TTS，只用系统自带的 say
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/src"
# shellcheck source=src/lib-ui.sh
source "$SRC/lib-ui.sh"

LINK="${AGENT_VOICE_LINK:-$HOME/.local/share/agent-voice/bin}"
CONFIG_PATH="${AGENT_VOICE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice/config.env}"
APP_HOME="${AGENT_VOICE_HOME:-$HOME/.local/share/agent-voice}"
BIN_DIR="$HOME/.local/bin"
LOG_DIR="$HOME/Library/Logs/agent-voice"
LABEL="com.agent-voice.kokoro-tts"
MODEL_BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"
MODELS=(kokoro-v1.1-zh.onnx voices-v1.1-zh.bin)

ASSUME_YES=""
WANT_KOKORO=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes)      ASSUME_YES=1 ;;
    --with-kokoro) WANT_KOKORO=yes ;;
    --no-kokoro)   WANT_KOKORO=no ;;
    -h|--help)     sed -n '2,7p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) ui_err "未知参数：$arg"; exit 1 ;;
  esac
done

# ---------- 探测 ----------
[[ "$(uname -s)" == "Darwin" ]] || { ui_err "只支持 macOS。"; exit 1; }
command -v python3 >/dev/null || { ui_err "需要 python3。"; exit 1; }

ARCH="$(uname -m)"
HAS_CLAUDE=""; [[ -d "$HOME/.claude" ]] && HAS_CLAUDE=1
HAS_CODEX="";  [[ -d "$HOME/.codex"  ]] && HAS_CODEX=1
IS_UPGRADE=""; [[ -e "$LINK" ]] && IS_UPGRADE=1

# 必须挑与 CPU 架构一致的 Python：装了 Rosetta 下的 Intel Python 时，
# onnxruntime 会跑在模拟层里慢好几倍。
PYBIN=""
for cand in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 \
            /usr/local/bin/python3.13 /usr/local/bin/python3.12 \
            "$(command -v python3.13 || true)" "$(command -v python3.12 || true)" \
            "$(command -v python3 || true)"; do
  [[ -x "$cand" ]] || continue
  if [[ "$("$cand" -c 'import platform;print(platform.machine())' 2>/dev/null)" == "$ARCH" ]]; then
    PYBIN="$cand"; break
  fi
done

MODELS_PRESENT=1
for f in "${MODELS[@]}"; do
  [[ -s "$APP_HOME/models/$f" ]] || MODELS_PRESENT=""
done

if [[ -z "$WANT_KOKORO" ]]; then
  if [[ -z "$PYBIN" ]]; then
    WANT_KOKORO=no
  elif [[ -n "$ASSUME_YES" ]]; then
    WANT_KOKORO=yes
  fi
fi

# ---------- 计划 ----------
printf '\n%sagent-voice%s  %s让 Claude Code / Codex 把回复念出来%s\n' \
  "$UI_BOLD" "$UI_RESET" "$UI_DIM" "$UI_RESET"
ui_title "$([[ -n "$IS_UPGRADE" ]] && echo '将要更新' || echo '将要安装')"

ui_row "脚本" "$LINK"
ui_row "命令" "$BIN_DIR/agent-voice"
ui_row "配置" "$CONFIG_PATH"
[[ -n "$HAS_CLAUDE" ]] && ui_row "Claude Code" "挂 Stop hook" \
                       || ui_row "Claude Code" "${UI_DIM}没装，跳过${UI_RESET}"
[[ -n "$HAS_CODEX" ]]  && ui_row "Codex" "挂 Stop hook（需一次性信任授权）" \
                       || ui_row "Codex" "${UI_DIM}没装，跳过${UI_RESET}"

if [[ "$WANT_KOKORO" != "no" ]]; then
  [[ -n "$MODELS_PRESENT" ]] \
    && ui_row "神经 TTS" "Kokoro 中文（模型已在本地）" \
    || ui_row "神经 TTS" "Kokoro 中文（要下约 400MB 模型）"
  [[ -n "$PYBIN" ]] && ui_row "Python" "$PYBIN ${UI_DIM}($ARCH)${UI_RESET}"
else
  ui_row "神经 TTS" "跳过，用系统自带 say"
fi
printf '\n'

if [[ -z "$WANT_KOKORO" ]]; then
  ui_confirm "装 Kokoro 神经 TTS 吗？音质接近真人，代价是约 400MB 模型。" y \
    && WANT_KOKORO=yes || WANT_KOKORO=no
fi
if [[ -z "$ASSUME_YES" ]]; then
  ui_confirm "开始安装？" y || { printf '\n已取消。\n\n'; exit 0; }
fi

UI_STEP_TOTAL=$([[ "$WANT_KOKORO" == "yes" ]] && echo 5 || echo 4)

# ---------- 1. 脚本与命令 ----------
ui_step "安装脚本"
mkdir -p "$(dirname "$LINK")" "$BIN_DIR"
ln -sfn "$SRC" "$LINK"
chmod +x "$SRC"/*.sh "$SRC"/*.py "$SRC/agent-voice"
ln -sfn "$LINK/agent-voice" "$BIN_DIR/agent-voice"
ui_ok "$LINK"
ui_ok "$BIN_DIR/agent-voice"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) ui_warn "$BIN_DIR 不在 PATH 里，加一行到 shell 配置："
     ui_info "export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ---------- 2. 配置 ----------
ui_step "配置文件"
mkdir -p "$(dirname "$CONFIG_PATH")"
if [[ -f "$CONFIG_PATH" ]]; then
  ui_skip "已存在，保留不动：$CONFIG_PATH"
else
  cp "$REPO/config.env.example" "$CONFIG_PATH"
  ui_ok "$CONFIG_PATH"
fi

# ---------- 3. 挂 hook ----------
ui_step "挂到两个 CLI 上"
wire_hook() {  # wire_hook <配置文件> <脚本名> <显示名>
  python3 - "$1" "$LINK/$2" "$3" <<'PY'
import json, pathlib, sys
path, cmd, label = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
cfg = json.loads(path.read_text()) if path.is_file() else {}
stop = cfg.setdefault("hooks", {}).setdefault("Stop", [])
if any(h.get("command") == cmd for e in stop for h in e.get("hooks", [])):
    print(f"SKIP {label} 已挂载")
else:
    if path.is_file():
        path.with_suffix(path.suffix + ".bak-agent-voice").write_text(path.read_text())
    stop.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
    print(f"OK {label} 已挂载")
PY
}
report() { [[ "$1" == SKIP* ]] && ui_skip "${1#SKIP }" || ui_ok "${1#OK }"; }

if [[ -n "$HAS_CLAUDE" ]]; then
  report "$(wire_hook "$HOME/.claude/settings.json" claude-stop.sh "Claude Code")"
else
  ui_skip "Claude Code 没装"
fi
if [[ -n "$HAS_CODEX" ]]; then
  report "$(wire_hook "$HOME/.codex/hooks.json" codex-turn-end.sh "Codex")"
  ui_warn "Codex 需要一次性信任授权：下次开交互式 codex 会弹确认，批准即可"
  ui_info "没批准的 hook 会被静默跳过，不报错也不出声"
else
  ui_skip "Codex 没装"
fi

# ---------- 4. Kokoro ----------
if [[ "$WANT_KOKORO" == "yes" ]]; then
  ui_step "本地神经 TTS"
  mkdir -p "$APP_HOME/models" "$LOG_DIR"

  if [[ -x "$APP_HOME/.venv/bin/python" ]]; then
    ui_skip "Python 环境已就绪"
  else
    ui_run "建 Python 环境" "$PYBIN" -m venv "$APP_HOME/.venv"
  fi
  ui_run "装依赖（kokoro-onnx / misaki）" \
    "$APP_HOME/.venv/bin/pip" install -q --upgrade pip kokoro-onnx "misaki[zh]" soundfile

  # 中文必须用 v1.1-zh 专用模型，默认的 voices-v1.0.bin 不含中文音色
  for f in "${MODELS[@]}"; do
    if [[ -s "$APP_HOME/models/$f" ]]; then
      ui_skip "模型 $f 已在本地"
    else
      printf '  下载 %s\n' "$f"
      curl -fL --retry 3 -# -o "$APP_HOME/models/$f" "$MODEL_BASE/$f"
      ui_ok "模型 $f"
    fi
  done

  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  sed -e "s|__SERVE_SH__|$LINK/kokoro-serve.sh|g" -e "s|__LOG_DIR__|$LOG_DIR|g" \
      "$REPO/launchd/$LABEL.plist.template" > "$PLIST"
  # bootout 是异步的，没等它彻底卸载就 bootstrap 会撞 "Input/output error"
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    for _ in $(seq 1 30); do
      launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
      sleep 0.3
    done
  fi
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ui_ok "常驻服务已托管（开机自启 + 挂掉自愈）"

  [[ "$UI_TTY" == "1" ]] && printf '  等待模型加载 '
  for _ in $(seq 1 60); do
    curl -sf --max-time 2 http://127.0.0.1:8127/health >/dev/null 2>&1 && break
    [[ "$UI_TTY" == "1" ]] && printf '.'
    sleep 1
  done
  [[ "$UI_TTY" == "1" ]] && printf '\r\033[K'
  if curl -sf --max-time 2 http://127.0.0.1:8127/health >/dev/null 2>&1; then
    ui_ok "服务已就绪"
  else
    ui_err "服务没起来，跑 agent-voice logs 看日志"
  fi
else
  python3 - "$CONFIG_PATH" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
if p.is_file():
    p.write_text(re.sub(r'AGENT_VOICE_ENGINE="\$\{AGENT_VOICE_ENGINE:-[a-z]+\}"',
                        'AGENT_VOICE_ENGINE="${AGENT_VOICE_ENGINE:-say}"', p.read_text()))
PY
fi

# ---------- 5. 语音输入（两个 CLI 的原生能力，与本项目无关） ----------
ui_step "语音输入（两个 CLI 自带，不需要本项目）"
if command -v sox >/dev/null 2>&1; then
  ui_ok "SoX 已装，Claude Code 的 Voice mode 可用"
else
  ui_warn "Claude Code 的 Voice mode 需要 SoX：brew install sox"
fi
if command -v codex >/dev/null 2>&1; then
  ui_warn "Codex 语音对话默认关闭：codex features enable realtime_conversation"
fi

# ---------- 完成 ----------
cat <<EOF

${UI_GREEN}${UI_BOLD}装好了。${UI_RESET}正常用 Claude Code / Codex 就会自动念了。

  ${UI_BOLD}agent-voice${UI_RESET}          看状态
  ${UI_BOLD}agent-voice test${UI_RESET}     立刻念一句听听
  ${UI_BOLD}agent-voice try${UI_RESET}      试听音色，选好用 agent-voice voice <名字>
  ${UI_BOLD}agent-voice off${UI_RESET}      临时静音
  ${UI_BOLD}agent-voice doctor${UI_RESET}   不出声时排查

EOF
