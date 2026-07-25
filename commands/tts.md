---
description: 语音播报开关 / 换音色 / 试听 / 排查不出声
allowed-tools: Bash(agent-voice:*)
---

用 Bash 执行 `agent-voice $ARGUMENTS`。

如果 `$ARGUMENTS` 为空，就执行 `agent-voice status`。

把命令的输出**原样**转述给用户，不要重新组织、不要补充解释、不要追加建议。
命令本身的输出已经是给人看的。

如果命令报错说找不到 `agent-voice`，告诉用户朗读引擎还没装，
需要先 clone https://github.com/ferry9303/agent-voice 跑一次 `./install.sh`。

可用参数：

| 参数 | 作用 |
|---|---|
| （空） | 看当前状态 |
| `on` / `off` | 开 / 关播报 |
| `test [句子]` | 立刻念一句 |
| `voices` | 列出全部 103 个音色 |
| `try [音色,音色]` | 试听音色 |
| `voice <音色>` | 设为默认音色 |
| `restart` | 重启合成服务 |
| `logs [行数]` | 看服务日志 |
| `doctor` | 体检，排查不出声 |
