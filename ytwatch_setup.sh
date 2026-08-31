#!/bin/bash
set -e

CHANNEL_URL="https://www.youtube.com/@marcinkowalski3226/videos"
CHECK_EVERY_MIN=60
LAST_N=3

echo "==> Krok 1/5: Sprawdzam Homebrew..."
if command -v brew >/dev/null 2>&1; then
    echo "    Homebrew jest zainstalowany: $(brew --version | head -1)"
else
    echo "    Brak Homebrew - instaluje (podaj haslo do Maca, gdy poprosi)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
    if [ -x /usr/local/bin/brew ];   then eval "$(/usr/local/bin/brew shellenv)";   fi
fi

echo "==> Krok 2/5: Instaluje / aktualizuje yt-dlp i ffmpeg..."
brew list yt-dlp >/dev/null 2>&1 || brew install yt-dlp
brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg
echo "    yt-dlp: $(yt-dlp --version)"

echo "==> Krok 3/5: Szukam folderu Dysku Google..."
GD_BASE=$(ls -d "$HOME/Library/CloudStorage"/GoogleDrive-* 2>/dev/null | head -1 || true)
OUT_DIR=""
if [ -n "$GD_BASE" ]; then
    for MYDRIVE in "Mój dysk" "My Drive"; do
        if [ -d "$GD_BASE/$MYDRIVE" ]; then
            OUT_DIR="$GD_BASE/$MYDRIVE/YouTube - Marcin Kowalski"
            break
        fi
    done
fi
if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$HOME/Movies/YouTube - Marcin Kowalski"
    echo "    Nie znalazlem aplikacji 'Dysk Google na komputer'."
    echo "    Filmy beda zapisywane lokalnie w: $OUT_DIR"
else
    echo "    Znalazlem Dysk Google. Filmy trafia do: $OUT_DIR"
fi
mkdir -p "$OUT_DIR"
mkdir -p "$HOME/.ytwatch"

echo "==> Krok 4/5: Tworze skrypt pobierajacy..."
YTDLP_BIN=$(command -v yt-dlp)
FFMPEG_DIR=$(dirname "$(command -v ffmpeg)")
cat > "$HOME/.ytwatch/pobierz.sh" <<EOF
#!/bin/bash
export PATH="$FFMPEG_DIR:\$PATH"
"$YTDLP_BIN" \\
  --download-archive "\$HOME/.ytwatch/pobrane.txt" \\
  --playlist-end $LAST_N \\
  -f "bv*+ba/b" \\
  --merge-output-format mp4 \\
  -o "$OUT_DIR/%(upload_date)s - %(title)s.%(ext)s" \\
  --no-progress \\
  --no-warnings \\
  "$CHANNEL_URL" >> "\$HOME/.ytwatch/log.txt" 2>&1
EOF
chmod +x "$HOME/.ytwatch/pobierz.sh"

echo "==> Krok 5/5: Wlaczam automatyczne sprawdzanie co ${CHECK_EVERY_MIN} min..."
PLIST="$HOME/Library/LaunchAgents/pl.pimpmybar.ytwatch.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>pl.pimpmybar.ytwatch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/.ytwatch/pobierz.sh</string>
    </array>
    <key>StartInterval</key><integer>$((CHECK_EVERY_MIN * 60))</integer>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "============================================================"
echo " GOTOWE!"
echo " Filmy trafiaja do: $OUT_DIR"
echo " Sprawdzanie: co ${CHECK_EVERY_MIN} minut (takze po restarcie Maca)"
echo " Pierwsze pobieranie (3 mecze) juz ruszylo w tle."
echo " Postep: tail -f ~/.ytwatch/log.txt"
echo "============================================================"
