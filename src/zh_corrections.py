"""开发语境下 pypinyin 会读错的多音词修正表。

pypinyin 的词库偏通用语料，技术词汇里的多音字经常判错——最典型的是「重」：
「重启」「重复」它认得，但「重装」「重试」「重构」全给成了 zhòng。
播报里这些词出现频率极高，必须修。

只收录**实测确认错误**的词。pypinyin 本来就对的（重启/重新/重建/重复/调用/
调试/差分/长度…）不要重复登记，登记了反而会在它将来修好后造成冲突。
"""

# 词 -> 每个字的带调拼音
CORRECTIONS: dict[str, list[list[str]]] = {
    # 「重」作「再一次」解时读 chóng
    "重装": [["chóng"], ["zhuāng"]],
    "重试": [["chóng"], ["shì"]],
    "重连": [["chóng"], ["lián"]],
    "重载": [["chóng"], ["zài"]],
    "重构": [["chóng"], ["gòu"]],
    "重跑": [["chóng"], ["pǎo"]],
    "重推": [["chóng"], ["tuī"]],
    "重置": [["chóng"], ["zhì"]],
    "重来": [["chóng"], ["lái"]],
    "重发": [["chóng"], ["fā"]],
    "重命名": [["chóng"], ["mìng"], ["míng"]],
    "重定向": [["chóng"], ["dìng"], ["xiàng"]],
    # 其它技术语境的多音字
    "调参": [["tiáo"], ["cān"]],
    "行数": [["háng"], ["shù"]],
    "长文": [["cháng"], ["wén"]],
    "部分": [["bù"], ["fen"]],
}


def apply() -> None:
    """把修正表灌进 pypinyin 的全局词库。

    misaki 的中文 G2P 内部调 lazy_pinyin，这里改的是同一份全局词库，
    所以不需要动 misaki 本身。
    """
    try:
        from pypinyin import load_phrases_dict
    except ImportError:
        return
    load_phrases_dict(CORRECTIONS)
