"""中英混排文本 → Kokoro 音素串。

misaki 的中文 G2P 会把非中文段原样透传，Kokoro 收到裸拉丁字母只能读错。
这里按「中文段 / 非中文段」切开分别处理，英文交给 espeak 出 IPA。
标点一律原样保留——Kokoro 靠它断句，丢了就会连读成一坨。
"""

import re

import zh_unaspirated

CJK = "一-鿿㐀-䶿豈-﫿"
SEGMENT = re.compile(f"[{CJK}]+|[^{CJK}]+")
IS_CJK = re.compile(f"[{CJK}]")
HAS_LATIN = re.compile(r"[A-Za-z]")
# 非中文段再切成「连续英文词组」和「其余字符」两类
WORD = r"[A-Za-z][A-Za-z'’.-]*"
LATIN_RUN = re.compile(f"{WORD}(?:[ \t]+{WORD})*|[^A-Za-z]+")


class MixedG2P:
    """线程不安全——每个进程建一个，串行调用。"""

    def __init__(self) -> None:
        import cn2an
        import espeakng_loader
        from misaki import zh
        from phonemizer.backend.espeak.wrapper import EspeakWrapper

        import zh_corrections

        # 必须在 misaki 之前灌进 pypinyin 的全局词库，修「重装」这类误读
        zh_corrections.apply()

        # espeakng_loader 自带的数据路径默认指向构建机，必须显式覆盖
        EspeakWrapper.set_library(espeakng_loader.get_library_path())
        EspeakWrapper.set_data_path(espeakng_loader.get_data_path())
        from phonemizer.backend import EspeakBackend

        self._cn2an = cn2an
        self._zh = zh.ZHG2P()
        self._en = EspeakBackend("en-us", preserve_punctuation=True, with_stress=True)

    def _english(self, words: str) -> str:
        try:
            return self._en.phonemize([words])[0].strip()
        except Exception:
            return ""

    def _non_chinese(self, segment: str) -> str:
        out = []
        for token in LATIN_RUN.findall(segment):
            out.append(self._english(token) if HAS_LATIN.match(token) else token)
        return "".join(out)

    def __call__(self, text: str) -> str:
        if not text.strip():
            return ""
        # 先把阿拉伯数字转成中文，否则切段后「3」会被当英文念成 three
        try:
            text = self._cn2an.transform(text, "an2cn")
        except Exception:
            pass

        parts = []
        for segment in SEGMENT.findall(text):
            if IS_CJK.search(segment):
                # 只改中文段：英文段的 p/t/k 是 espeak 出的真英语音，不能动
                parts.append(zh_unaspirated.fix(self._zh(segment)))
            else:
                parts.append(self._non_chinese(segment))
        return "".join(parts).strip()
