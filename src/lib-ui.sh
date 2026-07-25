# 终端输出helper。被 install.sh / uninstall.sh / agent-voice 共用。
# 非 tty 或设了 NO_COLOR 时自动降级成纯文本，方便重定向到日志。

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  UI_BOLD=$'\033[1m'; UI_DIM=$'\033[2m'; UI_RESET=$'\033[0m'
  UI_GREEN=$'\033[32m'; UI_YELLOW=$'\033[33m'; UI_RED=$'\033[31m'; UI_BLUE=$'\033[34m'
  UI_TTY=1
else
  UI_BOLD=""; UI_DIM=""; UI_RESET=""
  UI_GREEN=""; UI_YELLOW=""; UI_RED=""; UI_BLUE=""
  UI_TTY=0
fi

UI_STEP_TOTAL="${UI_STEP_TOTAL:-0}"
UI_STEP_N=0

ui_title() { printf '\n%s%s%s\n' "$UI_BOLD" "$1" "$UI_RESET"; }

ui_step() {
  UI_STEP_N=$((UI_STEP_N + 1))
  if [[ "$UI_STEP_TOTAL" -gt 0 ]]; then
    printf '\n%s[%d/%d]%s %s%s%s\n' \
      "$UI_DIM" "$UI_STEP_N" "$UI_STEP_TOTAL" "$UI_RESET" "$UI_BOLD" "$1" "$UI_RESET"
  else
    printf '\n%s%s%s\n' "$UI_BOLD" "$1" "$UI_RESET"
  fi
}

# 显示列宽。printf 的 %-Ns 按字节算，中文会错位；UTF-8 里 3 字节字符占 2 列。
# 注意：… — 这类「歧义宽度」字符也是 3 字节但多数终端只占 1 列，会算多一格，
# 所以标签里别用它们。
ui_width() {
  local s="$1" chars=${#1} bytes
  bytes=$(printf '%s' "$s" | LC_ALL=C wc -c | tr -d ' ')
  echo $(( chars + (bytes - chars) / 2 ))
}

# 对齐一行「标签  值」
ui_row() {
  local label="$1" value="$2" pad="${3:-16}" gap
  gap=$(( pad - $(ui_width "$label") )); (( gap < 1 )) && gap=1
  printf '  %s%*s%s\n' "$label" "$gap" "" "$value"
}

# 同上，但标签加粗。宽度按纯文本算——转义序列不占列。
ui_row_bold() {
  local label="$1" value="$2" pad="${3:-16}" gap
  gap=$(( pad - $(ui_width "$label") )); (( gap < 1 )) && gap=1
  printf '  %s%s%s%*s%s\n' "$UI_BOLD" "$label" "$UI_RESET" "$gap" "" "$value"
}

ui_ok()   { printf '  %s✓%s %s\n' "$UI_GREEN"  "$UI_RESET" "$1"; }
ui_skip() { printf '  %s·%s %s%s%s\n' "$UI_DIM" "$UI_RESET" "$UI_DIM" "$1" "$UI_RESET"; }
ui_warn() { printf '  %s!%s %s\n' "$UI_YELLOW" "$UI_RESET" "$1"; }
ui_err()  { printf '  %s✗%s %s\n' "$UI_RED"    "$UI_RESET" "$1" >&2; }
ui_info() { printf '    %s%s%s\n' "$UI_DIM" "$1" "$UI_RESET"; }

# ui_run "干什么" 命令...  —— 转菊花跑命令，失败时把日志吐出来
ui_run() {
  local msg="$1"; shift
  local log; log="$(mktemp)"
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local rc=0

  if [[ "$UI_TTY" == "1" ]]; then
    "$@" >"$log" 2>&1 &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s' "$UI_BLUE" "${frames[i % 10]}" "$UI_RESET" "$msg"
      i=$((i + 1))
      sleep 0.08
    done
    wait "$pid" || rc=$?
    printf '\r\033[K'
  else
    printf '  … %s\n' "$msg"
    "$@" >"$log" 2>&1 || rc=$?
  fi

  if [[ "$rc" -eq 0 ]]; then
    ui_ok "$msg"
  else
    ui_err "$msg"
    printf '%s' "$UI_DIM"; tail -15 "$log" >&2; printf '%s' "$UI_RESET"
  fi
  rm -f "$log"
  return "$rc"
}

# ui_confirm "问题" [默认y|n]
ui_confirm() {
  local prompt="$1" default="${2:-y}" hint answer
  [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
  [[ "$UI_TTY" == "1" ]] || { [[ "$default" == "y" ]]; return $?; }
  printf '\n%s %s[%s]%s ' "$prompt" "$UI_DIM" "$hint" "$UI_RESET"
  read -r answer </dev/tty || answer=""
  [[ -z "$answer" ]] && answer="$default"
  [[ "$answer" =~ ^[Yy] ]]
}
