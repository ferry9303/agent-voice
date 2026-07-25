#!/usr/bin/env python3
"""把一段 Markdown 回复压成一句适合朗读的中文播报。

stdin 收 Markdown 全文，stdout 出一行纯文本。
不调用任何模型——依赖「先结论后解说」的写作约定，取正文开头的完整句子。
"""

import os
import re
import sys


def _env_int(name: str, default: int) -> int:
    try:
        value = int(os.environ.get(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


# 播报长度。想更啰嗦就调大 AGENT_VOICE_MAX_CHARS，想只听一句就调小。
MAX_CHARS = _env_int("AGENT_VOICE_MAX_CHARS", 200)
MAX_SENTENCES = _env_int("AGENT_VOICE_MAX_SENTENCES", 6)
SENTENCE_END = "。！？!?；;"
# 长句收尾时可以切开的位置。刻意不含空格——在空格处切会把
# "Codex 用 notify" 截成 "Codex 用" 这种半截话。
CLAUSE_BREAK = SENTENCE_END + "，,、：:）)"

# 按顺序施加的清洗规则：(正则, 替换)
CLEAN_RULES = (
    (re.compile(r"```.*?```", re.S), " "),          # 围栏代码块
    (re.compile(r"~~~.*?~~~", re.S), " "),
    (re.compile(r"<!--.*?-->", re.S), " "),          # HTML 注释
    (re.compile(r"!\[[^\]]*\]\([^)]*\)"), " "),      # 图片
    (re.compile(r"\[([^\]]+)\]\([^)]*\)"), r"\1"),   # 链接保留文字
    (re.compile(r"`([^`]*)`"), r"\1"),               # 行内代码去反引号
    (re.compile(r"^\s{0,3}#{1,6}\s*", re.M), ""),    # 标题标记
    (re.compile(r"^\s*[-*+]\s+", re.M), ""),         # 无序列表标记
    (re.compile(r"^\s*\d+[.)]\s+", re.M), ""),       # 有序列表标记
    (re.compile(r"^\s*>\s?", re.M), ""),             # 引用标记
    (re.compile(r"^\s*\|.*\|\s*$", re.M), " "),      # 表格整行
    (re.compile(r"^\s*[-=]{3,}\s*$", re.M), " "),    # 分隔线
    (re.compile(r"\*\*|__|~~|\*|_"), ""),            # 粗体/斜体/删除线
    (re.compile(r"https?://\S+"), "链接"),            # 裸链接
    # 路径只留文件名：整段抹掉会把「改动点在 xxx」读成「改动点在 ，」
    (re.compile(r"[~\w.-]*/[\w.-]+(?:/[\w.-]+)+"), lambda m: m.group(0).rstrip("/").rsplit("/", 1)[-1]),
    (re.compile(r"[\U0001F300-\U0001FAFF☀-➿]"), ""),  # emoji
)

COLLAPSE_WS = re.compile(r"[ \t　]+")
COLLAPSE_NL = re.compile(r"\n{2,}")


def clean(text: str) -> str:
    for pattern, repl in CLEAN_RULES:
        text = pattern.sub(repl, text)
    text = COLLAPSE_WS.sub(" ", text)
    text = COLLAPSE_NL.sub("\n", text)
    return text.strip()


def split_sentences(text: str) -> list[str]:
    """按中英文句末标点切句；换行也当作句子边界。"""
    sentences: list[str] = []
    buf = ""
    for ch in text:
        if ch == "\n":
            if buf.strip():
                sentences.append(buf.strip())
            buf = ""
            continue
        buf += ch
        if ch in SENTENCE_END:
            sentences.append(buf.strip())
            buf = ""
    if buf.strip():
        sentences.append(buf.strip())
    return [s for s in sentences if s]


def pick(sentences: list[str]) -> str:
    """攒够 MAX_CHARS 就停，最多 MAX_SENTENCES 句。

    换行切出来的句子自带标点，标题/列表切出来的不带——后者要补个停顿，
    否则「结论」+「已修复缩略图链路」会连读成一句话。
    """
    picked: list[str] = []
    total = 0
    for sentence in sentences[:MAX_SENTENCES]:
        if picked and picked[-1][-1] not in SENTENCE_END:
            picked.append("，")
        picked.append(sentence)
        total += len(sentence)
        if total >= MAX_CHARS:
            break
    return "".join(picked)


def truncate(text: str) -> str:
    """超长时在句读处收尾，避免读半截。"""
    if len(text) <= MAX_CHARS:
        return text
    head = text[:MAX_CHARS]
    for i in range(len(head) - 1, MAX_CHARS // 3, -1):
        if head[i] in CLAUSE_BREAK:
            return head[: i + 1].rstrip("，,、：: ")
    return head.rstrip("，,、：: ")


def summarize(raw: str) -> str:
    body = clean(raw)
    if not body:
        return "任务完成"
    return truncate(pick(split_sentences(body))) or "任务完成"


def main() -> None:
    print(summarize(sys.stdin.read()))


if __name__ == "__main__":
    main()
