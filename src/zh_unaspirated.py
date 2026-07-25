"""把 misaki 的标准 IPA 不送气音改写成 Kokoro v1.1-zh 实际期望的写法。

拼音 b/d/g/z/zh/j 是**不送气清音**，标准 IPA 写作 p/t/k/ʦ/ʈʂ/ʨ，misaki 输出的
就是这套。但 kokoro-v1.1-zh 听感上把它们念成了送气音——「白」听着像「拍」。
实测同一个字改用浊音符号（b/d/ɡ/ʣ/ʤ/ʥ）才是对的，说明它训练时用的不是标准
IPA 这套对应。

送气音（带 ʰ）保持不变，所以映射必须排除后面跟着 ʰ 的情况。
只作用于中文段——英文段由 espeak 生成，那里的 p/t/k 是真的英语音。

已知代价：b/d/ɡ 在 IPA 里是**真浊音**（声带振动），普通话的 b/d/g 是不送气
清音，两者在普通话里不构成对立，但吴语/日语/英语里有——所以浊音一多会带出
一点口音。逐条试听后确认：辅音准确度优先，这点口音可接受，别再来回改。
"""

import re

# IPA 不送气 -> Kokoro 实际期望的符号。六组都逐对试听确认过，
# 一致是浊音符号那一版听着对，说明整套塞音/塞擦音都是同样的错位。
MAPPING = {
    "p": "b",   # 拼音 b
    "t": "d",   # 拼音 d
    "k": "ɡ",   # 拼音 g（U+0261，不是 ASCII g，词表里只有前者）
    "ʦ": "ʣ",   # 拼音 z
    "ꭧ": "ʤ",   # 拼音 zh
    "ʨ": "ʥ",   # 拼音 j
}


def _build(mapping: dict[str, str]) -> re.Pattern | None:
    if not mapping:
        return None
    # (?!ʰ) 是关键：pʰ 是拼音 p（送气），不能跟着一起改成 bʰ
    return re.compile("(" + "|".join(map(re.escape, mapping)) + ")(?!ʰ)")


_PATTERN = _build(MAPPING)


def fix(phonemes: str) -> str:
    """只对中文段的音素串调用。"""
    if _PATTERN is None:
        return phonemes
    return _PATTERN.sub(lambda m: MAPPING[m.group(1)], phonemes)
