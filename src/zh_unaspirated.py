"""把 misaki 的标准 IPA 不送气音改写成 Kokoro v1.1-zh 实际期望的写法。

拼音 b/d/g/z/zh/j 是**不送气清音**，标准 IPA 写作 p/t/k/ʦ/ʈʂ/ʨ，misaki 输出的
就是这套。但 kokoro-v1.1-zh 听感上把它们念成了送气音——「白」听着像「拍」。
实测同一个字改用浊音符号（b/d/ɡ/ʣ/ʤ/ʥ）才是对的，说明它训练时用的不是标准
IPA 这套对应。

送气音（带 ʰ）保持不变，所以映射必须排除后面跟着 ʰ 的情况。
只作用于中文段——英文段由 espeak 生成，那里的 p/t/k 是真的英语音。
"""

import re

# IPA 不送气 -> Kokoro 实际期望的符号。六组都逐对试听确认过，
# 一致是浊音符号那一版听着对，说明整套塞音/塞擦音都是同样的错位。
MAPPING = {
    "p": "b",   # 拼音 b
    "k": "ɡ",   # 拼音 g（U+0261，不是 ASCII g，词表里只有前者）
    "ʦ": "ʣ",   # 拼音 z
    "ꭧ": "ʤ",   # 拼音 zh
    "ʨ": "ʥ",   # 拼音 j
}

# t→d 试过又撤掉了：整句试听时「对不对」用 IPA 原样的 t 明显更自然，
# 换成 d 会浊化出口音。同一套里只有这一条不适用，别再想当然补回去。
REJECTED = {"t": "d"}


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
