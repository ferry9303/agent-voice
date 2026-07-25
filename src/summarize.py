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
    # 破折号在朗读里就是个停顿，转成逗号；不转的话 TTS 会把它当未知符号
    (re.compile(r"—{1,2}|――"), "，"),
    (re.compile(r"[「」『』《》〈〉]"), ""),            # 书名号/引号只是视觉标记
    # —— 以下三条专治「停顿插在词中间」——
    # 路径、包名、带冒号的命令里的 / : . 会原样进入音素流，Kokoro 拿它们当断句符，
    # 于是 commands/tts.md 会在词中间断两次。统一压成最后一个可读片段。
    (re.compile(r"[~\w.-]*(?:[/:][\w.-]+)+"),
     lambda m: re.split(r"[/:]", m.group(0).rstrip("/:"))[-1]),
    (re.compile(r"(?<![\w])/([A-Za-z][\w-]*)"), r"\1"),   # /tts 这类命令去掉前导斜杠
    # 去掉文件扩展名：".sh" 会被念成 "dot ess aitch"
    # 用 + 允许连续多个扩展名：kokoro-tts.err.log 要一次剥干净，
    # 只剥一层会剩下 kokoro-tts.err，那个点照样会断在词中间。
    (re.compile(
        r"\b([A-Za-z][\w-]*?)"
        r"(?:\.(?:sh|md|py|js|mjs|cjs|ts|tsx|jsx|json|toml|ya?ml|txt|log|onnx|bin|wav|plist"
        r"|env|cfg|conf|ini|lock|xml|csv|sql|rs|go|java|rb|php|c|h|cpp|swift|kt|err|out))+\b"),
     r"\1"),
    (re.compile(r"[\U0001F300-\U0001FAFF☀-➿]"), ""),  # emoji
)

# 一句话里非中文字符占比超过这个数，就当成代码行跳过——整句都是标识符时，
# 念出来是一串字母，既听不懂又打乱节奏。
CODE_DENSITY_LIMIT = 0.6
CJK_RE = re.compile("[一-鿿]")

COLLAPSE_WS = re.compile(r"[ \t　]+")
COLLAPSE_NL = re.compile(r"\n{2,}")


def clean(text: str) -> str:
    for pattern, repl in CLEAN_RULES:
        text = pattern.sub(repl, text)
    text = COLLAPSE_WS.sub(" ", text)
    text = COLLAPSE_NL.sub("\n", text)
    return text.strip()


def is_code_heavy(sentence: str) -> bool:
    """整句几乎全是标识符时返回 True。

    这种句子念出来是一长串字母，听不懂还打乱节奏。纯英文句子不算——
    判据是「有中文但中文占比很低」，也就是中文句子里塞满了代码。
    """
    body = sentence.strip()
    if len(body) < 8 or not CJK_RE.search(body):
        return False
    cjk = len(CJK_RE.findall(body))
    return (1 - cjk / len(body)) > CODE_DENSITY_LIMIT


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
    readable = [s for s in sentences if not is_code_heavy(s)] or sentences
    picked: list[str] = []
    total = 0
    for sentence in readable[:MAX_SENTENCES]:
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
