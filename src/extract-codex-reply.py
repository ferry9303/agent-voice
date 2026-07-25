#!/usr/bin/env python3
"""从 Codex 的事件载荷里取出本轮助手正文。

stdin 收一段事件 JSON（Stop hook 或 notify 都行），stdout 出正文。
按可靠性依次尝试：
  1. notify 的 last-assistant-message 字段（最直接）
  2. 载荷里指出的 rollout 文件
  3. ~/.codex/sessions 下最新的 rollout 文件（hook 载荷不带正文时的兜底）
"""

import argparse
import hashlib
import json
import pathlib
import sys

SESSIONS_DIR = pathlib.Path.home() / ".codex/sessions"
MESSAGE_KEYS = ("last-assistant-message", "last_assistant_message")
PATH_KEYS = ("rollout_path", "rollout-path", "transcript_path", "transcript-path")


def from_payload(event: dict) -> str:
    for key in MESSAGE_KEYS:
        value = event.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return ""


def rollout_from_payload(event: dict) -> pathlib.Path | None:
    for key in PATH_KEYS:
        value = event.get(key)
        if isinstance(value, str) and value:
            path = pathlib.Path(value)
            if path.is_file():
                return path
    return None


def newest_rollout() -> pathlib.Path | None:
    try:
        files = [p for p in SESSIONS_DIR.rglob("*.jsonl") if p.is_file()]
    except OSError:
        return None
    return max(files, key=lambda p: p.stat().st_mtime, default=None)


def from_rollout(path: pathlib.Path) -> str:
    """优先 final_answer 事件；退而求其次取最后一条 assistant 正文。"""
    final_answer = ""
    assistant_text = ""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return ""
    for line in lines:
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        kind = payload.get("type")
        if kind == "agent_message" and payload.get("phase") == "final_answer":
            final_answer = payload.get("message") or final_answer
        elif kind == "message" and payload.get("role") == "assistant":
            blocks = payload.get("content") or []
            text = "\n".join(
                b.get("text", "")
                for b in blocks
                if isinstance(b, dict) and b.get("type") in ("output_text", "text")
            ).strip()
            assistant_text = text or assistant_text
    return final_answer or assistant_text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default=None, help="记住上次播报过的内容指纹")
    args = parser.parse_args()

    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return
    if not isinstance(event, dict):
        return

    reply = from_payload(event)
    if not reply:
        path = rollout_from_payload(event) or newest_rollout()
        if path:
            reply = from_rollout(path)
    if not reply:
        return

    # rollout 兜底可能读到上一轮的内容，按指纹去重，绝不重复播报
    if args.state:
        state = pathlib.Path(args.state)
        digest = hashlib.sha1(reply.encode("utf-8")).hexdigest()
        try:
            if state.read_text(encoding="utf-8").strip() == digest:
                return
        except OSError:
            pass
        try:
            state.parent.mkdir(parents=True, exist_ok=True)
            state.write_text(digest, encoding="utf-8")
        except OSError:
            pass

    sys.stdout.write(reply)


if __name__ == "__main__":
    main()
