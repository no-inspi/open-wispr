#!/bin/zsh
# Installe la voix de Jarvis (Kokoro, voix française ff_siwis) comme service local.
# Relançable : ne retélécharge que ce qui manque et ne touche pas à la liste de mots
# déjà personnalisée.
set -euo pipefail

REPO=${0:A:h:h}
HOME_DIR=~/.local/share/open-wispr/kokoro
MODELS=$HOME_DIR/models
WORDS=~/.config/open-wispr/jarvis-english-words.txt
LABEL=com.charlie.open-wispr-voice
PLIST=~/Library/LaunchAgents/$LABEL.plist
SERVICE=gui/$(id -u)/$LABEL
LOG=~/Library/Logs/open-wispr-voice.log
PORT=47860
RELEASE=https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0

command -v uv >/dev/null || { echo "uv est requis : brew install uv" >&2; exit 1; }
mkdir -p "$MODELS" "${WORDS:h}"

uv venv -q --allow-existing --python 3.12 "$HOME_DIR/venv"
uv pip install -q --python "$HOME_DIR/venv/bin/python" "kokoro-onnx==0.6.1"

typeset -A SHA=(
    kokoro-v1.0.onnx 7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5
    voices-v1.0.bin  bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d
)
for file sum in ${(kv)SHA}; do
    if [[ ! -f $MODELS/$file ]] || ! echo "$sum  $MODELS/$file" | shasum -a 256 -c -s; then
        echo "Téléchargement de $file…"
        curl -sSL --fail -o "$MODELS/$file.part" "$RELEASE/$file"
        echo "$sum  $MODELS/$file.part" | shasum -a 256 -c -s \
            || { rm -f "$MODELS/$file.part"; echo "Empreinte invalide pour $file." >&2; exit 1; }
        mv "$MODELS/$file.part" "$MODELS/$file"
    fi
done

install -m 644 "$REPO/jarvis-voice/kokoro_server.py" "$HOME_DIR/kokoro_server.py"
[[ -f $WORDS ]] || install -m 644 "$REPO/jarvis-voice/english-words.txt" "$WORDS"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME_DIR/venv/bin/python</string>
    <string>$HOME_DIR/kokoro_server.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>JARVIS_VOICE_PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "$SERVICE" 2>/dev/null || true
# bootout rend la main avant l'arrêt complet : bootstrap échouerait.
for _ in {1..20}; do
    launchctl print "$SERVICE" >/dev/null 2>&1 || break
    sleep 0.5
done
launchctl bootstrap gui/$(id -u) "$PLIST"

for _ in {1..60}; do
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null; then
        echo "Voix Jarvis prête. Mots anglais : $WORDS"
        exit 0
    fi
    sleep 0.5
done
echo "Le service ne répond pas. Voir $LOG" >&2
exit 1
