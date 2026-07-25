#!/usr/bin/env python3
"""从 Claude Code 的 transcript JSONL 里取出本轮最后一条助手正文。

用法: extract-reply.py [--state FILE] [--wait SECONDS] <transcript.jsonl>

只认主线程（跳过 isSidechain 的子 agent），只认带 text 块的助手消息。

Stop hook 触发时本轮最终回复常常还没落盘，直接读会拿到上一条——这就是
「播报内容和上次一模一样」的根因。所以按 uuid 去重：读到的还是上次念过的
那条就轮询等新的，等不到就闭嘴，绝不重复播报。
"""

import argparse
import json
import pathlib
import sys
import time

POLL_INTERVAL = 0.25


def last_assistant(path: str) -> tuple[str, str]:
    """返回 (uuid, text)；没有可播报内容时返回 ("", "")。"""
    latest = ("", "")
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return latest
    with fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("type") != "assistant" or entry.get("isSidechain"):
                continue
            blocks = entry.get("message", {}).get("content") or []
            if not isinstance(blocks, list):
                continue
            text = "\n".join(
                b.get("text", "")
                for b in blocks
                if isinstance(b, dict) and b.get("type") == "text"
            ).strip()
            if text:
                latest = (entry.get("uuid") or "", text)
    return latest


def read_state(state: pathlib.Path | None) -> str:
    if state is None:
        return ""
    try:
        return state.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def write_state(state: pathlib.Path | None, uuid: str) -> None:
    if state is None or not uuid:
        return
    try:
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(uuid, encoding="utf-8")
    except OSError:
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript")
    parser.add_argument("--state", default=None, help="记住上次播报过的 uuid")
    parser.add_argument("--wait", type=float, default=0.0, help="等新消息的秒数")
    args = parser.parse_args()

    state = pathlib.Path(args.state) if args.state else None
    spoken = read_state(state)

    deadline = time.monotonic() + max(args.wait, 0.0)
    while True:
        uuid, text = last_assistant(args.transcript)
        if text and uuid != spoken:
            write_state(state, uuid)
            sys.stdout.write(text)
            return
        if time.monotonic() >= deadline:
            return  # 还是上次那条，宁可不念也不重复
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
