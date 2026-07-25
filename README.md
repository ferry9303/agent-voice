# agent-voice

给 **Claude Code** 和 **Codex CLI** 加语音：回复结束时自动念一句摘要出来。

语音**输入**不需要本项目——两个 CLI 都已经原生支持了，见 [语音输入](#语音输入)。
本项目只解决**输出**：让它把回复念给你听。

macOS only。

## 装

```bash
git clone https://github.com/ferry9303/agent-voice.git
cd agent-voice
./install.sh
```

安装器会先探测环境、把要做的事列出来，确认后再动手。会问你要不要装
Kokoro 本地神经 TTS（约 400MB 模型，音质接近真人）；不装就用系统自带的
`say`，零依赖但听着机械。`-y` 跳过所有提问，`--no-kokoro` 只装轻量版。

```
agent-voice  让 Claude Code / Codex 把回复念出来

将要安装
  脚本            ~/.local/share/agent-voice/bin
  命令            ~/.local/bin/agent-voice
  配置            ~/.config/agent-voice/config.env
  Claude Code     挂 Stop hook
  Codex           挂 Stop hook（需一次性信任授权）
  神经 TTS        Kokoro 中文（要下约 400MB 模型）
```

装完即生效，两个 CLI 都不用重启。重复跑安装器是幂等的，不会重下模型。

> Codex 侧还需要**一次性信任授权**：下次开交互式 `codex` 时会弹一个确认框，
> 批准即可。没批准的 hook 会被**静默跳过**——不报错也不出声，容易误以为没装上。

## 日常怎么用

装完就不用管了，正常用 Claude Code / Codex 就行。要调的都在 `agent-voice` 命令里：

```
agent-voice                 看当前状态
agent-voice test            立刻念一句听听
agent-voice voices          列出全部 103 个音色
agent-voice try zf_003,zm_010   试听指定音色
agent-voice voice zf_021    设为默认音色
agent-voice off / on        临时静音 / 恢复
agent-voice config          编辑配置
agent-voice restart         重启合成服务
agent-voice logs            看服务日志
agent-voice doctor          不出声时排查
```

音色分 `zf_*`（女声）和 `zm_*`（男声）。`agent-voice try` 不带参数会放几个
候选让你先听个大概，选中哪个再 `agent-voice voice <名字>` 定下来。

更细的调节改 `~/.config/agent-voice/config.env`，**改完立即生效**，不用重启：

| 想做什么 | 改哪个 |
|---|---|
| 播报太长/太短 | `AGENT_VOICE_MAX_CHARS`（默认 200，只想听一句就调到 60） |
| 念太快/太慢 | `AGENT_VOICE_SPEED`（默认 1.0） |
| 不想用 Kokoro | `AGENT_VOICE_ENGINE` 改成 `say` |

全部配置项见 [`config.env.example`](config.env.example)。卸载跑 `./uninstall.sh`
（加 `--purge` 连模型一起删）。

## 方案

```
Claude Code ──Stop hook──┐
                         ├─→ 取本轮回复正文 → 压成一句 → Kokoro 合成 → afplay
Codex CLI ────Stop hook──┘                                └ 失败则退回 say
```

几个设计取舍：

- **摘要不调模型。** 试过用 `claude -p --model haiku` 做真摘要，实测 10 秒才回来，
  太慢。改成直接抽回复开头几句——本来写作习惯就是「先结论后解说」，开头那句
  就是摘要，0 延迟 0 成本。想要真摘要把 `AGENT_VOICE_MODE` 改成 `llm`。
- **hook 必须立刻返回。** 等最终回复落盘要轮询几秒，所以 hook 先把自己重新拉起到
  后台再干活，主进程 0.1 秒就退出，不卡住 CLI。
- **常驻服务。** Kokoro 模型加载 + jieba 建词典要好几秒，每次现起进程根本没法用。
  服务由 launchd 托管，开机自启、挂掉自愈，合成稳定在 1.4 秒。
- **中英混排单独处理。** misaki 的中文 G2P 会把英文原样透传，
  「Stop hook」这种会被念错，所以英文单独走 espeak 出音素再拼回去。
- **断句自己控。** 整段一次性丢给模型，它自己的停顿忽长忽短——实测同一段里
  句号后 400ms、另一个句号后只有 120ms，听着就是不按标点走。改成按句末切开
  逐句合成、再插入固定长度静音。切到逗号一级会更规整，但模型对短片段会明显
  放慢语速（纯语音时长 +37%），所以默认只切句末，`AGENT_VOICE_CHUNK` 可调。

## 文件

| 文件 | 作用 |
|---|---|
| `src/claude-stop.sh` | Claude Code 的 `Stop` hook 适配器 |
| `src/codex-turn-end.sh` | Codex 的 `Stop` hook / `notify` 适配器（一个脚本两边通用） |
| `src/extract-reply.py` | 从 Claude Code transcript 取本轮正文，带去重与等待 |
| `src/extract-codex-reply.py` | 从 Codex 事件载荷或 rollout 文件取正文 |
| `src/summarize.py` | Markdown → 一句可朗读的中文 |
| `src/speak.sh` | 朗读核心：Kokoro 优先，失败退回 `say` |
| `src/kokoro_g2p.py` | 中英混排 → 音素 |
| `src/kokoro_server.py` | 常驻 TTS 服务，`127.0.0.1:8127` |
| `src/audition.sh` | 试听音色 |

运行时资源（不进 git）：`~/.local/share/agent-voice/`（venv + 模型）。

## 语音输入

两个 CLI 都已原生支持，装本项目与否都能用：

- **Claude Code** — 内置 Voice mode（按住说话 / 点一下开关听写）。
  需要 SoX（`brew install sox`）和已登录的 Claude.ai 账号。
- **Codex CLI** — `realtime_conversation` 特性，默认关闭：
  `codex features enable realtime_conversation`。是双向语音对话。

## 踩过的坑

记在这里省得别人再踩一遍：

- **Codex 的 hook 要信任授权。** 新增或改动 hook 命令后，Codex 会在交互式会话里弹一次
  确认，批准后才写进 `config.toml` 的 `hooks.state.*.trusted_hash`。
  没批准的 hook 静默跳过，`codex exec` 里完全看不出来。
- **Codex 的 `notify` 可能已被占用**（比如 Computer Use），它只能配一个程序。
  所以本项目走 `Stop` hook 而不是 `notify`。
- **`uv` 可能是 x86_64 二进制**，那样 `uv venv --python 3.12` 会挑到 Intel 版 Python，
  onnxruntime 就跑在 Rosetta 下慢好几倍。install.sh 里按 `uname -m` 匹配架构挑解释器。
- **Kokoro 的中文要 `v1.1-zh` 专用模型**，默认的 `voices-v1.0.bin` 不含中文音色。
- **`espeakng_loader` 自带的数据路径指向构建机**，必须 `EspeakWrapper.set_data_path()`
  显式覆盖，否则报 `phontab: No such file or directory`。
- **配置文件里别直接赋值。** `tts.env` 全部用 `${VAR:-默认}` 写法，
  否则 `AGENT_VOICE=0 某命令` 这种临时覆盖会被配置文件顶掉。
- **Stop hook 触发时最终回复常常还没落盘**，直接读 transcript 会拿到上一条，
  表现为「念的和上次一模一样」。所以按 uuid 去重并轮询等新消息，等不到就闭嘴。

## License

MIT
