#!/usr/bin/env bash
# 安装语音播报：给 Claude Code / Codex CLI 挂上「回复结束念一句摘要」。
#
#   ./install.sh                 交互式，会问要不要装 Kokoro
#   ./install.sh --with-kokoro   直接装本地神经 TTS（约 400MB 模型）
#   ./install.sh --no-kokoro     只用系统自带的 say，零依赖
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/src"
LINK="${AGENT_VOICE_LINK:-$HOME/.local/share/agent-voice/bin}"
CONFIG_PATH="${AGENT_VOICE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-voice/config.env}"
APP_HOME="${AGENT_VOICE_HOME:-$HOME/.local/share/agent-voice}"
LOG_DIR="$HOME/Library/Logs/agent-voice"
LABEL="com.agent-voice.kokoro-tts"
MODEL_BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"

WANT_KOKORO=""
for arg in "$@"; do
  case "$arg" in
    --with-kokoro) WANT_KOKORO=yes ;;
    --no-kokoro)   WANT_KOKORO=no ;;
    -h|--help)     sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

say_step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
say_ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
say_warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }

[[ "$(uname -s)" == "Darwin" ]] || { echo "只支持 macOS。" >&2; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3。" >&2; exit 1; }

# ---------- 1. 脚本软链 ----------
say_step "挂载脚本目录"
mkdir -p "$(dirname "$LINK")"
ln -sfn "$SRC" "$LINK"
chmod +x "$SRC"/*.sh "$SRC"/*.py
say_ok "$LINK -> $SRC"

# ---------- 2. 配置文件 ----------
say_step "配置文件"
CONF="$CONFIG_PATH"
mkdir -p "$(dirname "$CONF")"
if [[ -f "$CONF" ]]; then
  say_ok "已存在，保留不动：$CONF"
else
  mkdir -p "$(dirname "$CONF")"
  cp "$REPO/config.env.example" "$CONF"
  say_ok "已创建：$CONF"
fi

# ---------- 3. 挂 Claude Code 的 Stop hook ----------
say_step "Claude Code"
if [[ -d "$HOME/.claude" ]]; then
  python3 - "$LINK" <<'PY'
import json, pathlib, sys
link = sys.argv[1]
path = pathlib.Path.home() / ".claude/settings.json"
cfg = json.loads(path.read_text()) if path.is_file() else {}
cmd = f"{link}/claude-stop.sh"
stop = cfg.setdefault("hooks", {}).setdefault("Stop", [])
if any(h.get("command") == cmd for e in stop for h in e.get("hooks", [])):
    print("    \033[32m✓\033[0m Stop hook 已挂载")
else:
    if path.is_file():
        backup = path.with_suffix(".json.bak-agent-voice")
        backup.write_text(path.read_text())
    stop.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
    path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
    print("    \033[32m✓\033[0m 已写入 Stop hook")
PY
else
  say_warn "没找到 ~/.claude，跳过"
fi

# ---------- 4. 挂 Codex 的 Stop hook ----------
say_step "Codex CLI"
if [[ -d "$HOME/.codex" ]]; then
  python3 - "$LINK" <<'PY'
import json, pathlib, sys
link = sys.argv[1]
path = pathlib.Path.home() / ".codex/hooks.json"
cfg = json.loads(path.read_text()) if path.is_file() else {}
cmd = f"{link}/codex-turn-end.sh"
stop = cfg.setdefault("hooks", {}).setdefault("Stop", [])
if any(h.get("command") == cmd for e in stop for h in e.get("hooks", [])):
    print("    \033[32m✓\033[0m Stop hook 已挂载")
else:
    if path.is_file():
        path.with_suffix(".json.bak-agent-voice").write_text(path.read_text())
    stop.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
    path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
    print("    \033[32m✓\033[0m 已写入 Stop hook")
PY
  say_warn "Codex 的 hook 需要一次性信任授权：下次开交互式 codex 会弹确认，批准即可。"
  say_warn "没批准的 hook 会被静默跳过，不报错也不出声。"
else
  say_warn "没找到 ~/.codex，跳过"
fi

# ---------- 5. Kokoro 本地神经 TTS（可选） ----------
if [[ -z "$WANT_KOKORO" ]]; then
  printf '\n装本地 Kokoro 神经 TTS 吗？音质接近真人，但要下约 400MB 模型。\n'
  printf '不装的话用系统自带的 say，零依赖但听着机械。 [Y/n] '
  read -r answer </dev/tty || answer=n
  [[ "$answer" =~ ^[Nn] ]] && WANT_KOKORO=no || WANT_KOKORO=yes
fi

if [[ "$WANT_KOKORO" == "yes" ]]; then
  say_step "Kokoro 本地 TTS"

  # 必须挑与 CPU 架构一致的 Python。装了 Rosetta 下的 Intel Python 时，
  # onnxruntime 会跑在模拟层里，慢好几倍。
  ARCH="$(uname -m)"
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
  [[ -n "$PYBIN" ]] || { echo "找不到与 $ARCH 匹配的 python3.12/3.13。" >&2; exit 1; }
  say_ok "用 ${PYBIN}（${ARCH}）"

  mkdir -p "$APP_HOME/models"
  if [[ ! -x "$APP_HOME/.venv/bin/python" ]]; then
    "$PYBIN" -m venv "$APP_HOME/.venv"
    say_ok "已建 venv"
  else
    say_ok "venv 已存在"
  fi

  "$APP_HOME/.venv/bin/pip" install -q --upgrade pip
  "$APP_HOME/.venv/bin/pip" install -q kokoro-onnx "misaki[zh]" soundfile
  say_ok "依赖就绪"

  # 中文必须用 v1.1-zh 专用模型，默认的 voices-v1.0.bin 不含中文音色
  for f in kokoro-v1.1-zh.onnx voices-v1.1-zh.bin; do
    if [[ -s "$APP_HOME/models/$f" ]]; then
      say_ok "$f 已存在"
    else
      echo "    下载 $f …"
      curl -fL --retry 3 --progress-bar -o "$APP_HOME/models/$f" "$MODEL_BASE/$f"
      say_ok "$f 下载完成"
    fi
  done

  mkdir -p "$LOG_DIR"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  sed -e "s|__SERVE_SH__|$LINK/kokoro-serve.sh|g" \
      -e "s|__LOG_DIR__|$LOG_DIR|g" \
      "$REPO/launchd/$LABEL.plist.template" > "$PLIST"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  say_ok "常驻服务已托管给 launchd（开机自启 + 挂掉自愈）"

  printf '    等待服务就绪 '
  for _ in $(seq 1 60); do
    if curl -sf --max-time 2 http://127.0.0.1:8127/health >/dev/null 2>&1; then
      printf '\n'; say_ok "服务已就绪"; break
    fi
    printf '.'; sleep 1
  done
else
  say_step "Kokoro"
  say_ok "跳过，使用系统自带 say"
  python3 - <<'PY'
import pathlib, re
p = pathlib.Path.home() / ".config/agent-voice/config.env"
if p.is_file():
    t = p.read_text()
    t = re.sub(r'AGENT_VOICE_ENGINE="\$\{AGENT_VOICE_ENGINE:-[a-z]+\}"',
               'AGENT_VOICE_ENGINE="${AGENT_VOICE_ENGINE:-say}"', t)
    p.write_text(t)
PY
fi

# ---------- 6. 语音输入（两个 CLI 都是原生能力） ----------
say_step "语音输入"
if command -v sox >/dev/null 2>&1; then
  say_ok "SoX 已安装，Claude Code 的 Voice mode 可用"
elif command -v brew >/dev/null 2>&1; then
  say_warn "Claude Code 的 Voice mode 需要 SoX：brew install sox"
else
  say_warn "Claude Code 的 Voice mode 需要 SoX（先装 Homebrew）"
fi
if command -v codex >/dev/null 2>&1; then
  say_warn "Codex 语音对话默认关闭：codex features enable realtime_conversation"
fi

cat <<EOF

$(printf '\033[1m装好了。\033[0m')

  试听音色      $LINK/audition.sh
  列出全部音色  $LINK/audition.sh -l
  只听某几个    $LINK/audition.sh -v zf_003,zm_010
  改配置        \$EDITOR ~/.config/agent-voice/config.env
  临时静音      在 ~/.config/agent-voice/config.env 里把 AGENT_VOICE 改成 0

EOF
