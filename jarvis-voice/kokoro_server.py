"""Voix de Jarvis : Kokoro (voix française ff_siwis) servi en local.

POST /speak avec {"text": "..."} renvoie un WAV. Les mots listés dans le fichier
de mots anglais sont prononcés à l'anglaise, le reste en français. Le fichier est
relu dès qu'il change : on peut l'éditer sans redémarrer le service.
"pronunciations": {"mot": "phonèmes"} impose en plus une prononciation pour cet appel.

Apprentissage d'une prononciation par la voix :
POST /learn {"takes": ["chemin.wav", ...]} renvoie {"phonemes": "...", "takes": [...]} ;
POST /words {"word": "...", "phonemes": "..."} l'enregistre dans le fichier de mots.
POST /prepare {} charge le modèle de phonèmes à l'avance.
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
LEARN_DIR = Path(os.environ.get("JARVIS_VOICE_LEARN_DIR", Path.home() / ".config/open-wispr/learn"))
PHONEME_MODEL = "facebook/wav2vec2-xlsr-53-espeak-cv-ft"
PHONEME_REVISION = "3e836924cfd3b858a0bbdbc1f7ef412105d00446"
MAX_TEXT = 5000
MAX_TAKES = 5


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


def edit_distance(a: str, b: str) -> int:
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def choose_phonemes(candidates: list[str]) -> str | None:
    """La transcription la plus fréquente ; à égalité, la plus proche des autres."""
    candidates = [c for c in candidates if c]
    if not candidates:
        return None
    best = max(candidates, key=candidates.count)
    lengths = {len(c) for c in candidates}
    if candidates.count(best) == 1 and len(lengths) == 1:
        # Prises toutes différentes mais de même longueur : vote son par son.
        columns = zip(*candidates)
        return "".join(max(column, key=column.count) for column in columns)
    return min(candidates, key=lambda c: (-candidates.count(c), sum(edit_distance(c, o) for o in candidates)))


def set_word(path: Path, word: str, phonemes: str):
    """Remplace la ligne du mot (casse ignorée) ou l'ajoute à la fin."""
    line = f"{word} = {phonemes}"
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    for i, existing in enumerate(lines):
        name = existing.split("#", 1)[0].partition("=")[0].strip()
        if name.lower() == word.lower():
            lines[i] = line
            break
    else:
        lines.append(line)
    temporary = path.with_suffix(".tmp")
    temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
    temporary.replace(path)


def trim_silence(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    loud = np.where(np.abs(audio) > 0.02 * np.abs(audio).max())[0] if audio.size else []
    if len(loud) == 0:
        return audio
    margin = sample_rate // 10
    return audio[max(0, loud[0] - margin): loud[-1] + 1 + margin]


class Listener:
    """Reconnaissance de phonèmes, chargée au premier apprentissage seulement."""

    def __init__(self):
        self.lock = threading.Lock()
        self.model = None

    def load(self):
        if self.model is None:
            from transformers import AutoModelForCTC, Wav2Vec2FeatureExtractor, Wav2Vec2PhonemeCTCTokenizer
            self.features = Wav2Vec2FeatureExtractor.from_pretrained(PHONEME_MODEL, revision=PHONEME_REVISION)
            self.decoder = Wav2Vec2PhonemeCTCTokenizer.from_pretrained(
                PHONEME_MODEL, revision=PHONEME_REVISION, do_phonemize=False)
            self.model = AutoModelForCTC.from_pretrained(PHONEME_MODEL, revision=PHONEME_REVISION).eval()

    def phonemes(self, path: Path) -> str:
        import soundfile
        import torch
        audio, sample_rate = soundfile.read(path, dtype="float32", always_2d=True)
        audio = trim_silence(audio.mean(axis=1), sample_rate)
        if sample_rate != 16000:
            raise ValueError(f"échantillonnage {sample_rate} Hz, 16000 attendu")
        with self.lock:
            self.load()
            inputs = self.features(audio, sampling_rate=sample_rate, return_tensors="pt")
            with torch.no_grad():
                ids = self.model(inputs.input_values).logits.argmax(-1)
            return self.decoder.batch_decode(ids)[0].replace(" ", "")


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

    def kokoro_phonemes(self, phonemes: str) -> str:
        """Garde seulement les symboles que Kokoro sait prononcer."""
        return "".join(c for c in phonemes if c in self.tokenizer.vocab)

    def wav(self, text: str, pronunciations: dict[str, str] | None = None) -> bytes:
        with self.lock:
            self.refresh_words()
            words, pattern = self.words, self.pattern
            if pronunciations:
                words = {**words, **{w.lower(): p for w, p in pronunciations.items()}}
                pattern = english_pattern(words)
            phonemes = phonemize(text, pattern, self.tokenizer.phonemize, words)
            samples, sample_rate = self.kokoro.create(phonemes, voice=VOICE, speed=SPEED, is_phonemes=True)
        return to_wav(samples, sample_rate)


class Handler(BaseHTTPRequestHandler):
    voice: Voice
    listener: Listener

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, b"ok", "text/plain")
        else:
            self.reply(404, b"not found", "text/plain")

    def do_POST(self):
        routes = {"/speak": self.speak, "/learn": self.learn, "/words": self.save_word, "/prepare": self.prepare}
        if self.path not in routes:
            return self.reply(404, b"not found", "text/plain")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise TypeError
        except (ValueError, TypeError):
            return self.reply(400, b"expected a JSON object", "text/plain")
        try:
            routes[self.path](body)
        except (KeyError, TypeError, ValueError) as error:
            self.reply(400, str(error).encode(), "text/plain")

    def reply_json(self, value):
        self.reply(200, json.dumps(value, ensure_ascii=False).encode(), "application/json")

    def prepare(self, body):
        """Charge le modèle de phonèmes en tâche de fond pendant que Charlie parle."""
        def load():
            with self.listener.lock:
                self.listener.load()
        threading.Thread(target=load, daemon=True).start()
        self.reply_json({"ok": True})

    def learn(self, body):
        takes = [Path(p).resolve() for p in body["takes"]][:MAX_TAKES]
        root = LEARN_DIR.resolve()
        if not takes or any(root not in t.parents or t.suffix != ".wav" for t in takes):
            raise ValueError(f"takes must be .wav files in {LEARN_DIR}")
        try:
            heard = [self.voice.kokoro_phonemes(self.listener.phonemes(t)) for t in takes]
        except Exception as error:
            print(f"apprentissage impossible : {error}", file=sys.stderr, flush=True)
            return self.reply(500, b"learning failed", "text/plain")
        self.reply_json({"phonemes": choose_phonemes(heard), "takes": heard})

    def save_word(self, body):
        word, phonemes = str(body["word"]).strip(), self.voice.kokoro_phonemes(str(body["phonemes"]))
        if not word or "=" in word or "#" in word or "\n" in word or not phonemes:
            raise ValueError("invalid word or phonemes")
        with self.voice.lock:
            set_word(WORDS_FILE, word, phonemes)
        self.reply_json({"word": word, "phonemes": phonemes})

    def speak(self, body):
        text = str(body["text"]).strip()[:MAX_TEXT]
        pronunciations = body.get("pronunciations") or {}
        if not isinstance(pronunciations, dict):
            raise TypeError("pronunciations must be an object")
        if not text:
            raise ValueError("empty text")
        try:
            audio = self.voice.wav(text, {str(w): self.voice.kokoro_phonemes(str(p))
                                          for w, p in pronunciations.items()})
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
    Handler.listener = Listener()
    Handler.voice.wav("Prêt.")  # préchauffe le modèle
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Voix Jarvis prête sur {HOST}:{PORT} ({VOICE})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
