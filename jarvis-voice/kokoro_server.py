"""Voix de Jarvis : Kokoro (voix française ff_siwis) servi en local.

POST /speak avec {"text": "..."} renvoie un WAV. Les mots listés dans le fichier
de mots anglais sont prononcés à l'anglaise, le reste en français. Le fichier est
relu dès qu'il change : on peut l'éditer sans redémarrer le service.
"""

import io
import json
import os
import re
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
from kokoro_onnx import Kokoro
from kokoro_onnx.tokenizer import Tokenizer

HOST = "127.0.0.1"
PORT = int(os.environ.get("JARVIS_VOICE_PORT", "47860"))
VOICE = os.environ.get("JARVIS_VOICE", "ff_siwis")
SPEED = float(os.environ.get("JARVIS_VOICE_SPEED", "1.0"))
MODELS = Path(os.environ.get("JARVIS_VOICE_MODELS", Path.home() / ".local/share/open-wispr/kokoro/models"))
WORDS_FILE = Path(os.environ.get("JARVIS_VOICE_WORDS", Path.home() / ".config/open-wispr/jarvis-english-words.txt"))
MAX_TEXT = 5000


def read_words(path: Path) -> dict[str, str | None]:
    """Un mot ou une expression par ligne ; # commence un commentaire.

    « mot = phonèmes » impose une prononciation (alphabet de Kokoro) ;
    sinon le mot est prononcé à l'anglaise.
    """
    words = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        entry = line.split("#", 1)[0]
        word, _, phonemes = entry.partition("=")
        if word.strip():
            words[word.strip().lower()] = phonemes.strip() or None
    return words


def english_pattern(words) -> re.Pattern | None:
    if not words:
        return None
    # Les expressions longues d'abord, pour que « pull request » passe avant « pull ».
    alternatives = "|".join(re.escape(w) for w in sorted(set(words), key=len, reverse=True))
    return re.compile(rf"(?<!\w)(?:{alternatives})(?!\w)", re.IGNORECASE)


def split_by_language(text: str, pattern: re.Pattern | None) -> list[tuple[str, str]]:
    """Découpe le texte en morceaux (langue, texte), sans perdre aucun caractère."""
    if pattern is None:
        return [("fr-fr", text)] if text else []
    parts, last = [], 0
    for match in pattern.finditer(text):
        if match.start() > last:
            parts.append(("fr-fr", text[last:match.start()]))
        parts.append(("en-us", match.group(0)))
        last = match.end()
    if last < len(text):
        parts.append(("fr-fr", text[last:]))
    return parts


def phonemize(text: str, pattern: re.Pattern | None, phonemize_part, overrides=None) -> str:
    """Phonémise chaque morceau dans sa langue en gardant les espaces qui l'entourent."""
    overrides = overrides or {}
    out = []
    for lang, part in split_by_language(text, pattern):
        core = part.strip()
        if not core:
            out.append(" " if part else "")
            continue
        lead = " " if part[0].isspace() else ""
        trail = " " if part[-1].isspace() else ""
        forced = overrides.get(core.lower()) if lang == "en-us" else None
        out.append(lead + (forced or phonemize_part(core, lang)) + trail)
    return re.sub(r" {2,}", " ", "".join(out)).strip()


def to_wav(samples: np.ndarray, sample_rate: int) -> bytes:
    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2")
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(sample_rate)
        f.writeframes(pcm.tobytes())
    return buffer.getvalue()


class Voice:
    def __init__(self):
        self.kokoro = Kokoro(str(MODELS / "kokoro-v1.0.onnx"), str(MODELS / "voices-v1.0.bin"))
        self.tokenizer = Tokenizer()
        self.lock = threading.Lock()
        self.words_mtime = None
        self.pattern = None
        self.words = {}

    def refresh_words(self):
        try:
            mtime = WORDS_FILE.stat().st_mtime
        except FileNotFoundError:
            self.words_mtime, self.pattern, self.words = None, None, {}
            return
        if mtime != self.words_mtime:
            self.words = read_words(WORDS_FILE)
            self.pattern = english_pattern(self.words)
            self.words_mtime = mtime

    def wav(self, text: str) -> bytes:
        with self.lock:
            self.refresh_words()
            phonemes = phonemize(text, self.pattern, self.tokenizer.phonemize, self.words)
            samples, sample_rate = self.kokoro.create(phonemes, voice=VOICE, speed=SPEED, is_phonemes=True)
        return to_wav(samples, sample_rate)


class Handler(BaseHTTPRequestHandler):
    voice: Voice

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, b"ok", "text/plain")
        else:
            self.reply(404, b"not found", "text/plain")

    def do_POST(self):
        if self.path != "/speak":
            return self.reply(404, b"not found", "text/plain")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            text = str(json.loads(self.rfile.read(length))["text"]).strip()[:MAX_TEXT]
        except (ValueError, KeyError, TypeError):
            return self.reply(400, b"expected {\"text\": \"...\"}", "text/plain")
        if not text:
            return self.reply(400, b"empty text", "text/plain")
        try:
            audio = self.voice.wav(text)
        except Exception as error:  # le client retombe sur la voix macOS
            print(f"synthèse impossible : {error}", file=sys.stderr, flush=True)
            return self.reply(500, b"synthesis failed", "text/plain")
        self.reply(200, audio, "audio/wav")

    def reply(self, code: int, body: bytes, content_type: str):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def main():
    Handler.voice = Voice()
    Handler.voice.wav("Prêt.")  # préchauffe le modèle
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Voix Jarvis prête sur {HOST}:{PORT} ({VOICE})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
