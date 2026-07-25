"""常驻的 Kokoro 中文 TTS 服务。

模型加载要 1 秒出头，G2P 初始化更久，所以进程常驻、只在启动时加载一次。
监听 127.0.0.1，不对外暴露。

  GET  /health          -> 200 ok
  POST /speak           -> audio/wav
       {"text": "...", "voice": "zf_017", "speed": 1.0}

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
DEFAULT_VOICE = os.environ.get("AGENT_VOICE_KOKORO_VOICE", "zf_017")
MAX_BODY = 64 * 1024

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


def to_wav(samples, sample_rate: int) -> bytes:
    import numpy as np

    pcm = np.clip(np.asarray(samples), -1.0, 1.0)
    pcm = (pcm * 32767).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(sample_rate)
        fh.writeframes(pcm.tobytes())
    return buf.getvalue()


def synthesize(text: str, voice: str, speed: float) -> bytes:
    with _lock:
        phonemes = _g2p(text)
        if not phonemes:
            return b""
        samples, sample_rate = _engine.create(
            phonemes, voice=voice, speed=speed, is_phonemes=True
        )
    return to_wav(samples, sample_rate)


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
