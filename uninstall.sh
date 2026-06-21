#!/bin/bash
set -e
BIN_DIR="$HOME/.local/bin"
echo "Removing portal-games..."
rm -f "$BIN_DIR/portal-games"
echo "Stopping friends-presence service..."
systemctl --user disable --now portal-friends.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/portal-friends.service"
systemctl --user daemon-reload 2>/dev/null || true
rm -f "$BIN_DIR/portal-friends"
echo "  (kept ~/.config/Plasma-App-Portal/config.json with your API key)"
echo "Removing widget(s)..."
for id in org.devl0rd.portal; do
    kpackagetool6 -t Plasma/Applet -r "$id" >/dev/null 2>&1 && echo "  removed $id" || true
done
echo "Done. (Custom art in ~/.local/share/Plasma-App-Portal was left in place.)"
