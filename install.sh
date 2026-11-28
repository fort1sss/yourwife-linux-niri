#!/bin/bash
# Installs the Your Wife Linux/niri setup for the current user.
#   ./install.sh            from a git clone: scripts go to ~/.local/bin
#   yourwife-setup          from the AUR package: scripts are already in /usr/bin, only per-user setup
# Works on stock niri too; niri built with patches/niri-yourwife.patch adds cursor gaze,
# smooth resizing and "above fullscreen" (see README).
set -e
SRC="$(dirname "$(readlink -f "$0")")"
cd "$SRC"

if [ "$1" = "--system" ]; then
    BIN=/usr/bin
else
    BIN="$HOME/.local/bin"
    for f in yourwife yw-gaze niri-pin yw-tray yw-menu-catcher yw-extract-icon; do
        install -Dm755 "bin/$f" "$BIN/$f"
    done
fi

# ── dependencies (names as in Arch)
missing=()
command -v xwayland-satellite >/dev/null || missing+=(xwayland-satellite)
[ -e /usr/lib/libgtk4-layer-shell.so ] || missing+=(gtk4-layer-shell)
python3 -c 'import gi' 2>/dev/null || missing+=(python-gobject)
ldconfig -p 2>/dev/null | grep -q libXtst.so || missing+=(libxtst)
command -v magick >/dev/null || missing+=(imagemagick)
[ ${#missing[@]} -eq 0 ] || echo "!! missing packages: ${missing[*]}   (sudo pacman -S ${missing[*]})"

# ── niri rules: drop the lines that need the niri patch if the running niri does not know them
NIRI=~/.config/niri
install -Dm644 niri/magenta-key.frag "$NIRI/shaders/magenta-key.frag"
sed "s|@BIN@|$BIN|g" niri/yourwife.kdl > "$NIRI/yourwife.kdl"
grep -q 'include "yourwife.kdl"' "$NIRI/config.kdl" || printf '\ninclude "yourwife.kdl"\n' >> "$NIRI/config.kdl"
[ -e "$NIRI/yourwife-keys.kdl" ] || printf 'binds {\n    Mod+Ctrl+Y { spawn "%s" "togglehide"; }\n}\n' "$BIN/yourwife" > "$NIRI/yourwife-keys.kdl"
grep -q 'include "yourwife-keys.kdl"' "$NIRI/config.kdl" || printf '\ninclude "yourwife-keys.kdl"\n' >> "$NIRI/config.kdl"
if niri validate >/dev/null 2>&1; then
    PATCHED=1
else
    sed -i '/needs-patch/d' "$NIRI/yourwife.kdl"
    PATCHED=0
    echo "niri without patches/niri-yourwife.patch: works, but without cursor gaze, smooth resize and above-fullscreen"
fi

# ── game files
LIB="${STEAM_LIBRARY:-$HOME/.local/share/Steam}"
GAME="$LIB/steamapps/common/YourWife"
PFX="$LIB/steamapps/compatdata/3339420/pfx"
USERDATA="$PFX/drive_c/users/steamuser/AppData/Roaming/Godot/app_userdata/你的老婆"
for f in linux_key.gd linux_menu_window.gd linux_menu.gd linux_workshop_window.gd; do
    install -Dm644 "game/$f" "$USERDATA/$f"
done
touch "$USERDATA/linux_alpha"   # true transparency mode
echo "game scripts -> $USERDATA"
if [ -d "$GAME" ]; then
    install -Dm644 game/override.cfg "$GAME/override.cfg"; echo "override.cfg -> $GAME"
    "$BIN/yw-extract-icon" "$GAME/YourWife.exe" || echo "!! could not extract the tray icon"
else
    echo "!! game folder not found ($GAME): install the game, run it once, then re-run this"
fi

# ── Wine: 32-bit (ARGB) windows = real alpha instead of black; fast fonts for the game's UI
WINE=$(ls -d "$LIB"/steamapps/common/Proton*/files/bin/wine 2>/dev/null | tail -1)
if [ -n "$WINE" ] && [ -d "$PFX" ]; then
    WINEPREFIX="$PFX" WINEDEBUG=-all "$WINE" reg add 'HKCU\Software\Wine\X11 Driver' /v ScreenDepth /t REG_SZ /d 32 /f >/dev/null
    if fc-list | grep -q NotoSansCJK; then
        for f in "Microsoft YaHei UI" "Microsoft YaHei"; do
            WINEPREFIX="$PFX" WINEDEBUG=-all "$WINE" reg add 'HKCU\Software\Wine\Fonts\Replacements' /v "$f" /t REG_SZ /d "Noto Sans CJK SC" /f >/dev/null
        done
    else
        echo "!! install noto-fonts-cjk: the game's UI font is replaced with Noto Sans CJK"
    fi
else
    echo "!! Proton prefix not found: run the game once from Steam, then re-run this"
fi

niri validate >/dev/null 2>&1 && echo "Done$([ $PATCHED = 1 ] && echo ' (patched niri: all features)').
Steam -> Your Wife -> Properties -> Launch options:  DISPLAY=:2 %command%   (and turn the Steam overlay off)
Then log out of niri and back in."
