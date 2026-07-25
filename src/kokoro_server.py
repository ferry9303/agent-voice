"""常驻的 Kokoro 中文 TTS 服务。

模型加载要 1 秒出头，G2P 初始化更久，所以进程常驻、只在启动时加载一次。
监听 127.0.0.1，不对外暴露。

  GET  /health          -> 200 ok
  POST /speak           -> audio/wav
       {"text": "...", "voice": "zf_001", "speed": 1.0}

环境变量：
  AGENT_VOICE_HOME    模型与 venv 所在目录，默认 ~/.local/share/agent-voice
  AGENT_VOICE_PORT    监听端口，默认 8127
"""

import io
import json
import os
import pathlib
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = pathlib.Path(
    os.environ.get("AGENT_VOICE_HOME", pathlib.Path.home() / ".local/share/agent-voice")
)
PORT = int(os.environ.get("AGENT_VOICE_PORT", "8127"))
MODEL = HOME / "models/kokoro-v1.1-zh.onnx"
VOICES = HOME / "models/voices-v1.1-zh.bin"
DEFAULT_VOICE = os.environ.get("AGENT_VOICE_KOKORO_VOICE", "zf_001")
MAX_BODY = 64 * 1024

# 各级标点切开后要插入的静音（毫秒），仅在 CHUNK_MODE 不是 off 时生效
_SCALE = float(os.environ.get("AGENT_VOICE_PAUSE_SCALE", "1.0"))
_SENTENCE = {"。": 380, "！": 380, "？": 380, "…": 380,
             ".": 380, "!": 380, "?": 380,
             "；": 300, ";": 300, "\n": 380}
_CLAUSE = {"，": 240, ",": 240, "：": 260, ":": 260, "、": 170}

# 切分粒度：
#   off（默认）  整段一次合成。语速最自然——切片会让模型对短片段放慢语速，
#                实测纯语音时长 sentence +22%、clause +37%，听感上发拖。
#                代价是停顿时长由模型自己决定，句号和逗号的轻重不太分得开。
#   sentence     只在句末切，句间插入固定静音，停顿层次稳定
#   clause       连逗号也切，最规整但最拖
CHUNK_MODE = os.environ.get("AGENT_VOICE_CHUNK", "off")
_ACTIVE = {"sentence": _SENTENCE, "clause": {**_SENTENCE, **_CLAUSE}}.get(CHUNK_MODE, {})
PAUSE_MS = {ch: int(ms * _SCALE) for ch, ms in _ACTIVE.items()}

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

_lock = threading.Lock()   # kokoro / misaki 都不是线程安全的
_engine = None
_g2p = None


def load() -> None:
    global _engine, _g2p
    from kokoro_onnx import Kokoro

    from kokoro_g2p import MixedG2P

    _engine = Kokoro(str(MODEL), str(VOICES))
    _g2p = MixedG2P()
    _g2p("预热一下 warm up。")  # 首次调用会建 jieba 词典，提前吃掉这份延迟


# 模型输出本身偏小：实测峰值 0.39、RMS -23.6 dBFS，而系统 say 是 -17.2 dBFS，
# 同样的系统音量下听着小一半。按 RMS 归一到常见的语音响度，再用峰值上限兜底防削波。
TARGET_RMS_DB = float(os.environ.get("AGENT_VOICE_TARGET_RMS_DB", "-18"))
PEAK_CEILING = 0.95


def normalize(samples):
    import numpy as np

    audio = np.asarray(samples, dtype="float32")
    peak = float(np.abs(audio).max()) if audio.size else 0.0
    rms = float(np.sqrt((audio.astype("float64") ** 2).mean())) if audio.size else 0.0
    if peak <= 0 or rms <= 0:
        return audio
    target = 10 ** (TARGET_RMS_DB / 20)
    # 取两者较小的那个增益：响度够了但绝不削波
    gain = min(target / rms, PEAK_CEILING / peak)
    return audio * gain


def to_wav(samples, sample_rate: int) -> bytes:
    import numpy as np

    pcm = np.clip(normalize(samples), -1.0, 1.0)
    pcm = (pcm * 32767).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(sample_rate)
        fh.writeframes(pcm.tobytes())
    return buf.getvalue()


def split_for_prosody(text: str) -> list[tuple[str, int]]:
    """按标点切片，返回 [(片段, 片段后要插入的静音毫秒)]。

    整段一次性丢给模型时，它自己的停顿时长完全不受控——实测同一段里
    句号后 400ms、另一个句号后却只有 120ms。切开逐句合成再插入固定间隔，
    才能让「句号 > 分号 > 逗号」的层次稳定下来。
    """
    segments: list[tuple[str, int]] = []
    buf = ""
    for ch in text:
        buf += ch
        pause = PAUSE_MS.get(ch)
        if pause is not None:
            if buf.strip():
                segments.append((buf, pause))
            buf = ""
    if buf.strip():
        segments.append((buf, 0))
    return segments or [(text, 0)]


def synthesize(text: str, voice: str, speed: float) -> bytes:
    import numpy as np

    chunks = []
    sample_rate = 24000
    with _lock:
        for segment, pause in split_for_prosody(text):
            phonemes = _g2p(segment)
            if not phonemes:
                continue
            # trim=True 会削掉模型自带的首尾静音，这样插进去的间隔就是唯一的停顿
            samples, sample_rate = _engine.create(
                phonemes, voice=voice, speed=speed, is_phonemes=True, trim=True
            )
            chunks.append(np.asarray(samples))
            if pause > 0:
                chunks.append(np.zeros(int(sample_rate * pause / 1000), dtype="float32"))
    if not chunks:
        return b""
    return to_wav(np.concatenate(chunks), sample_rate)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args) -> None:  # 别把 launchd 日志刷爆
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send(200, b"ok", "text/plain")
        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self) -> None:
        if self.path != "/speak":
            self._send(404, b"not found", "text/plain")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            self._send(400, b"bad length", "text/plain")
            return
        try:
            payload = json.loads(self.rfile.read(length))
            text = str(payload["text"])
            voice = str(payload.get("voice") or DEFAULT_VOICE)
            speed = float(payload.get("speed") or 1.0)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            self._send(400, b"bad request", "text/plain")
            return

        try:
            wav = synthesize(text, voice, speed)
        except Exception as exc:  # 合成失败要让客户端能回退到 say
            self._send(500, str(exc).encode()[:500], "text/plain")
            return
        if not wav:
            self._send(204, b"", "text/plain")
            return
        self._send(200, wav, "audio/wav")


def main() -> None:
    if not MODEL.is_file() or not VOICES.is_file():
        sys.exit(f"缺少模型文件：{MODEL} / {VOICES}")
    load()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"kokoro-tts listening on 127.0.0.1:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
