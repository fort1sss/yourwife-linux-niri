#!/bin/bash
# Installs the Your Wife Linux/niri setup for the current user.
# Does NOT build niri — see README (niri-shaders + patches/niri-yourwife.patch).
set -e
cd "$(dirname "$(readlink -f "$0")")"
install -Dm755 bin/yourwife  ~/.local/bin/yourwife
install -Dm755 bin/yw-gaze   ~/.local/bin/yw-gaze
install -Dm755 bin/niri-pin  ~/.local/bin/niri-pin
install -Dm644 niri/magenta-key.frag ~/.config/niri/shaders/magenta-key.frag
install -Dm644 niri/yourwife.kdl        ~/.config/niri/yourwife.kdl
grep -q 'include "yourwife.kdl"' ~/.config/niri/config.kdl || printf '\ninclude "yourwife.kdl"\n' >> ~/.config/niri/config.kdl
GAME="${STEAM_LIBRARY:-$HOME/.local/share/Steam}/steamapps/common/YourWife"
USERDATA="${STEAM_LIBRARY:-$HOME/.local/share/Steam}/steamapps/compatdata/3339420/pfx/drive_c/users/steamuser/AppData/Roaming/Godot/app_userdata/你的老婆"
install -Dm644 game/linux_key.gd "$USERDATA/linux_key.gd"; echo "linux_key.gd -> $USERDATA"
touch "$USERDATA/linux_alpha"   # режим справжньої прозорості
# Wine: 32-бітні (ARGB) вікна — справжній альфа-канал замість чорного фону
PFX="${STEAM_LIBRARY:-$HOME/.local/share/Steam}/steamapps/compatdata/3339420/pfx"
WINE=$(ls -d "${STEAM_LIBRARY:-$HOME/.local/share/Steam}"/steamapps/common/Proton*/files/bin/wine 2>/dev/null | tail -1)
if [ -n "$WINE" ] && [ -d "$PFX" ]; then
    WINEPREFIX="$PFX" WINEDEBUG=-all "$WINE" reg add 'HKCU\Software\Wine\X11 Driver' /v ScreenDepth /t REG_SZ /d 32 /f
else echo "Proton/prefix not found: run the game once, then re-run install.sh"; fi
if [ -d "$GAME" ]; then install -Dm644 game/override.cfg "$GAME/override.cfg"; echo "override.cfg -> $GAME"
else echo "Game folder not found ($GAME). Copy game/override.cfg next to YourWife.exe yourself."; fi
niri validate && echo "Done. Set Steam launch options: DISPLAY=:2 %command%  and re-login to niri."
