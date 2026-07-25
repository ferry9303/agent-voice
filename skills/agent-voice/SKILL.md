---
name: agent-voice
description: 控制语音播报（把回复念出来）——开关、换音色、试听、排查不出声。当用户说「关掉语音」「太吵了」「换个声音」「念一句听听」「怎么不出声了」之类的话时使用。
---

# agent-voice

本机装了 agent-voice：Claude Code / Codex 回复结束时会自动念一句摘要。
控制它用 `agent-voice` 命令，**直接跑，不要改配置文件**。

## 常用操作

| 用户想干什么 | 跑什么 |
|---|---|
| 关掉播报 / 太吵了 | `agent-voice off` |
| 重新打开 | `agent-voice on` |
| 现在什么状态 | `agent-voice` |
| 念一句听听 | `agent-voice test` |
| 换个声音 | `agent-voice try` 试听，选中后 `agent-voice voice <音色>` |
| 有哪些声音 | `agent-voice voices`（103 个，`zf_*` 女声、`zm_*` 男声） |
| 不出声了 | `agent-voice doctor` |
| 服务卡住 | `agent-voice restart` |

把命令输出原样转述给用户即可，它本身就是给人看的，不用重新组织。

## 更细的调节

改 `~/.config/agent-voice/config.env`，**改完立即生效**，不用重启：

- `AGENT_VOICE_MAX_CHARS` 播报长度，默认 200，只想听一句就调到 60
- `AGENT_VOICE_SPEED` 语速倍率，默认 1.0
- `AGENT_VOICE_ENGINE` `auto` / `kokoro` / `say`

## 排查不出声

按顺序看：

1. `agent-voice doctor` —— 一次性检查配置、模型、服务、SoX
2. 服务没响应就 `agent-voice restart`
3. 还不行看 `agent-voice logs`

如果是 **Codex 侧完全没反应**，多半是 hook 没通过信任授权：Codex 对新增或改动过的
hook 会弹一次确认，没批准的会被**静默跳过**——不报错也不出声。开一次交互式
codex 批准即可。

## 不归它管的事

用户说的「语音输入」（说话变文字）跟 agent-voice 无关，那是两个 CLI 各自的原生
功能：Claude Code 用 `/voice`，Codex 用 `realtime_conversation` 特性。
别去改 agent-voice 的配置。
