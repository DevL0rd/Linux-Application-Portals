#!/bin/bash
set -e

REPO_DIR=$(pwd)
if [ ! -f "$REPO_DIR/bin/portal-games" ]; then
    echo "Please run this script from the repository directory."
    exit 1
fi

BIN_DIR="$HOME/.local/bin"
PLASMOID_SRC="$REPO_DIR/plasmoids"

for bin in python3 kpackagetool6; do
    command -v "$bin" >/dev/null 2>&1 || echo "Warning: '$bin' is not installed or not in PATH."
done

# --- 1. games backend onto PATH (symlinked back to the repo) ---
mkdir -p "$BIN_DIR"
chmod +x "$REPO_DIR/bin/portal-games"
ln -sf "$REPO_DIR/bin/portal-games" "$BIN_DIR/portal-games"
echo "Linked portal-games into $BIN_DIR"

# --- 1b. friends-presence backend + config + resident service ---
chmod +x "$REPO_DIR/bin/portal-friends"
ln -sf "$REPO_DIR/bin/portal-friends" "$BIN_DIR/portal-friends"
echo "Linked portal-friends into $BIN_DIR"

CFG_DIR="$HOME/.config/Plasma-App-Portal"
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG_DIR/config.json" ]; then
    cp "$REPO_DIR/config.example.json" "$CFG_DIR/config.json"
    echo "Created $CFG_DIR/config.json -- paste your free Steam Web API key there"
    echo "  (get one at https://steamcommunity.com/dev/apikey)"
fi

mkdir -p "$HOME/.config/systemd/user"
# pin the resident collector to the E-cores, same as the router/log collectors
AFFINITY=""
ECORES=$(python3 -S "$REPO_DIR/bin/portal-ecores" 2>/dev/null)
[ -n "$ECORES" ] && AFFINITY="CPUAffinity=$ECORES" && echo "Pinning portal-friends to efficiency cores: $ECORES"
cat > "$HOME/.config/systemd/user/portal-friends.service" <<EOF
[Unit]
Description=App Portal friends-presence collector
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $REPO_DIR/bin/portal-friends --serve
Restart=always
RestartSec=10
Nice=19
$AFFINITY

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now portal-friends.service >/dev/null 2>&1 \
    && echo "Enabled portal-friends.service (friends badge in the Games view)" \
    || echo "  (could not enable portal-friends.service -- enable it manually)"

# --- 1c. let the Friends widget read the tmpfs snapshot in-process via QML XHR ---
# (Qt blocks file:// XHR unless this is set.) environment.d is applied by the
# systemd user manager, so it survives mid-session plasma restarts too.
mkdir -p "$HOME/.config/environment.d"
echo 'QML_XHR_ALLOW_FILE_READ=1' > "$HOME/.config/environment.d/linux-plasma-portals.conf"
systemctl --user set-environment QML_XHR_ALLOW_FILE_READ=1 2>/dev/null || true
echo "Set QML_XHR_ALLOW_FILE_READ=1 (environment.d; survives plasma restarts)"

# --- 2. install the plasmoid(s) ---
echo "Installing widget(s)..."
for d in "$PLASMOID_SRC"/org.devl0rd.portal*; do
    if kpackagetool6 -t Plasma/Applet -u "$d" >/dev/null 2>&1; then
        echo "  upgraded $(basename "$d")"
    else
        kpackagetool6 -t Plasma/Applet -i "$d" >/dev/null 2>&1 && echo "  installed $(basename "$d")"
    fi
done

echo ""
echo "Done! Add it via right-click panel -> Add Widgets -> search \"App Portal\"."
echo "If it doesn't appear yet, run:  systemctl --user restart plasma-plasmashell.service"
echo "Friends badge: add your Steam Web API key to $HOME/.config/Plasma-App-Portal/config.json"

# reload Plasma at the end -- unless --no-reload (so bulk installs can reload once)
if ! printf '%s\n' "$@" | grep -qx -- --no-reload; then
    echo "Reloading Plasma…"
    # plasmashell may be run by plasma-plasmashell.service OR as an app-plasmashell@<hash>
    # scope (then plasma-plasmashell.service is inactive and "restarting" it just spawns a
    # doomed duplicate). Restart the unit only when it actually runs the shell; otherwise
    # quit + relaunch the running instance directly.
    if systemctl --user --quiet is-active plasma-plasmashell.service; then
        systemctl --user restart plasma-plasmashell.service
    else
        kquitapp6 plasmashell 2>/dev/null; (kstart plasmashell >/dev/null 2>&1 &)
    fi
fi
