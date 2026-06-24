/*
 * Plasma-App-Portal :: Steam Friends
 * A friends-list popup that mirrors the App Portal look: a search field plus a
 * sort/filter dropdown in the top bar, then a live list of friends with avatars,
 * presence (in-game / online / away / offline) and a right-click action menu.
 *
 * Optimised like the Process Monitor: the snapshot the resident `portal-friends`
 * collector writes to tmpfs is read IN-PROCESS via XHR (file://) -- no subprocess
 * per poll -- and the visible rows live in a ListModel that is reconciled in place
 * (insert/move/set/remove keyed by steamid) so delegates PERSIST and only the
 * changed values update; the whole list is never destroyed/recreated on refresh.
 * (Needs QML_XHR_ALLOW_FILE_READ=1, set by install.sh via environment.d.)
 *
 * "Favourites" are our own per-instance pins (Steam doesn't expose its own),
 * sorted into a section at the top.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    property string panelIcon: "im-user"
    function refreshIcon() { panelIcon = (Plasmoid.configuration.icon || "im-user") }
    Plasmoid.icon: root.panelIcon
    Plasmoid.title: i18n("Steam Friends")
    Connections { target: Plasmoid.configuration; function onIconChanged() { root.refreshIcon() } }

    // ---- state ----
    property var friends: []                 // raw list from the snapshot
    property var friendsById: ({})           // steamid -> friend, looked up live in delegates
    property string error: ""
    property bool saving: false
    property string searchText: ""
    // toolbar state is per-applet-instance (persisted), like the App Portal
    property string sortMode: Plasmoid.configuration.sortMode      // name|name_desc
    property bool hideOffline: Plasmoid.configuration.hideOffline
    property string favorites: Plasmoid.configuration.favorites    // comma-separated steamids
    onSearchTextChanged: rebuild()
    onSortModeChanged: rebuild()
    onHideOfflineChanged: rebuild()
    onFavoritesChanged: rebuild()

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // ---- favourites (our own; comma-separated steamids in config) ----
    function favoritesList() {
        return (root.favorites || "").split(",").filter(function(s) { return s !== "" })
    }
    function isFavorite(sid) { return favoritesList().indexOf(String(sid)) >= 0 }
    function toggleFavorite(sid) {
        sid = String(sid)
        var l = favoritesList(); var i = l.indexOf(sid)
        if (i >= 0) l.splice(i, 1); else l.push(sid)
        Plasmoid.configuration.favorites = l.join(",")    // -> root.favorites -> rebuild()
    }

    // ---- presence helpers (personastate: 0 off,1 on,2 busy,3 away,4 snooze,5/6 on) ----
    readonly property color cInGame: "#90ba3c"
    readonly property color cOnline: "#57cbde"
    readonly property color cAway:   "#7e9bb5"
    readonly property color cOffline: "#6a6a6a"
    function stateColor(f) {
        if (!f) return cOffline
        if (f.ingame) return cInGame
        if (f.state === 0) return cOffline
        if (f.state === 2 || f.state === 3 || f.state === 4) return cAway
        return cOnline
    }
    function stateText(f) {
        if (!f) return ""
        if (f.ingame) return f.game || i18n("In game")
        switch (f.state) {
        case 0: return i18n("Offline")
        case 2: return i18n("Busy")
        case 3: return i18n("Away")
        case 4: return i18n("Snooze")
        default: return i18n("Online")
        }
    }

    readonly property int onlineCount: (root.friends || []).filter(function(f) {
        return f.ingame || f.state !== 0
    }).length

    // "last online" for offline friends (Steam's value can be stale; shown as-is)
    function lastOnlineText(f) {
        if (!f || f.ingame || f.state !== 0) return ""
        var t = f.lastlogoff || 0
        if (!t) return ""
        var diff = Date.now() / 1000 - t
        if (diff < 60) return i18n("just now")
        var y = Math.floor(diff / 31536000)
        if (y >= 1) return i18n("%1y ago", y)
        var d = Math.floor(diff / 86400)
        if (d >= 1) return i18n("%1d ago", d)
        var h = Math.floor(diff / 3600)
        if (h >= 1) return i18n("%1h ago", h)
        return i18n("%1m ago", Math.floor(diff / 60))
    }

    // ISO country code -> regional-indicator flag emoji (rendered with the emoji font)
    function flagEmoji(cc) {
        if (!cc || String(cc).length !== 2) return ""
        var s = String(cc).toUpperCase()
        var a = s.charCodeAt(0) - 65, b = s.charCodeAt(1) - 65
        if (a < 0 || a > 25 || b < 0 || b > 25) return ""
        return String.fromCodePoint(0x1F1E6 + a) + String.fromCodePoint(0x1F1E6 + b)
    }

    // ---- sections: Favourites -> In Game -> Online -> Offline ----
    function sectionOf(f, fav) {
        if (fav) return i18n("Favourites")
        if (f.ingame) return i18n("In Game")
        if (f.state === 0) return i18n("Offline")
        return i18n("Online")
    }
    function sectionRank(f, fav) {
        if (fav) return 0
        if (f.ingame) return 1
        if (f.state === 0) return 3
        return 2
    }

    // ---- data: read the tmpfs snapshot in-process (no subprocess per poll) ----
    property string cachePath: ""
    P5Support.DataSource {
        id: pathHelper
        engine: "executable"
        onNewData: function(source, d) {
            root.cachePath = (d.stdout || "").trim()
            disconnectSource(source)
            root.read()
        }
    }
    function read() {
        if (!cachePath) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + cachePath)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (!xhr.responseText) { root.error = i18n("No snapshot — is the collector running?"); return }
            root.processSnapshot(xhr.responseText)
        }
        xhr.send()
    }
    function processSnapshot(text) {
        var s
        try { s = JSON.parse(text || "{}") } catch (e) { root.error = i18n("Could not read friends data"); return }
        root.error = (s.ok === false) ? (s.error || i18n("No data")) : ""
        root.saving = false
        var list = s.friends || []
        var byId = {}
        for (var i = 0; i < list.length; i++) byId[String(list[i].steamid)] = list[i]
        root.friends = list
        root.friendsById = byId        // delegates re-look-up their row from this
        root.rebuild()
    }

    // build the desired ordered rows (steamid + section + fav) and reconcile in place
    function rebuild() {
        var q = root.searchText.toLowerCase()
        var favs = root.favoritesList()
        var dir = root.sortMode === "name_desc" ? -1 : 1
        var list = root.friends || []
        var rows = []
        for (var i = 0; i < list.length; i++) {
            var f = list[i]
            if (root.hideOffline && !f.ingame && f.state === 0) continue
            if (q !== "" && (f.name || "").toLowerCase().indexOf(q) < 0) continue
            var fav = favs.indexOf(String(f.steamid)) >= 0
            rows.push({ steamid: String(f.steamid), name: f.name || "", fav: fav,
                        section: root.sectionOf(f, fav), rank: root.sectionRank(f, fav) })
        }
        rows.sort(function(x, y) {
            if (x.rank !== y.rank) return x.rank - y.rank
            return dir * x.name.localeCompare(y.name)
        })
        var desired = rows.map(function(r) {
            return { steamid: r.steamid, section: r.section, fav: r.fav }
        })
        root.syncModel(desired)
    }

    // reconcile rowModel against `desired`, keyed by steamid: keep delegates alive,
    // only insert/move/remove the diff and set() rows whose section/fav changed
    ListModel { id: rowModel }
    function syncModel(desired) {
        var n = desired.length
        var want = {}
        for (var i = 0; i < n; i++) want[desired[i].steamid] = true
        for (var r = rowModel.count - 1; r >= 0; r--)        // drop gone rows
            if (want[rowModel.get(r).steamid] !== true) rowModel.remove(r)
        for (var pos = 0; pos < n; pos++) {
            var d = desired[pos]
            if (pos < rowModel.count && rowModel.get(pos).steamid === d.steamid) {
                var a = rowModel.get(pos)                     // already in place
                if (a.section !== d.section || a.fav !== d.fav) rowModel.set(pos, d)
                continue
            }
            var cur = -1
            for (var x = pos + 1; x < rowModel.count; x++)
                if (rowModel.get(x).steamid === d.steamid) { cur = x; break }
            if (cur < 0) {
                rowModel.insert(pos, d)                       // new row
            } else {
                rowModel.move(cur, pos, 1)                    // moved row
                var b = rowModel.get(pos)
                if (b.section !== d.section || b.fav !== d.fav) rowModel.set(pos, d)
            }
        }
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    function steamRun(url) { if (url) runner.connectSource("steam " + root.shq(url)) }

    // write the API key into the shared config, then restart the collector so it
    // re-authenticates immediately (it also re-reads the key on its next poll)
    function saveKey(k) {
        k = String(k).trim()
        if (k === "") return
        root.saving = true
        runner.connectSource("$HOME/.local/bin/portal-friends --set-key " + root.shq(k)
            + " ; systemctl --user restart portal-friends.service")
        setupReloadTimer.restart()
    }
    Timer { id: setupReloadTimer; interval: 4000; repeat: false; onTriggered: root.read() }

    // event-driven: re-read the instant the collector rewrites the snapshot (no polling)
    FileWatcher { path: root.cachePath; onChanged: root.read() }
    Component.onCompleted: {
        refreshIcon()
        pathHelper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Plasma-App-Portal/friends.json\"")
    }
    onExpandedChanged: if (expanded) read()

    // ---- right-click action menu ----
    QQC2.Menu {
        id: friendMenu
        property var friend: null
        QQC2.MenuItem {
            text: i18n("Open Chat"); icon.name: "mail-message"
            onTriggered: root.steamRun(friendMenu.friend.chat)
        }
        QQC2.MenuItem {
            text: i18n("Join Game"); icon.name: "media-playback-start"
            visible: friendMenu.friend && friendMenu.friend.join
            height: visible ? implicitHeight : 0
            onTriggered: root.steamRun(friendMenu.friend.join)
        }
        QQC2.MenuItem {
            text: i18n("Watch Game"); icon.name: "video-television"
            visible: friendMenu.friend && friendMenu.friend.ingame
            height: visible ? implicitHeight : 0
            onTriggered: root.steamRun(friendMenu.friend.watch)
        }
        QQC2.MenuSeparator {}
        QQC2.MenuItem {
            text: i18n("View Profile"); icon.name: "steam"
            onTriggered: root.steamRun(friendMenu.friend.profile)
        }
        QQC2.MenuSeparator {}
        QQC2.MenuItem {
            text: root.isFavorite(friendMenu.friend ? friendMenu.friend.steamid : "")
                ? i18n("Remove from Favourites") : i18n("Add to Favourites")
            icon.name: "starred-symbolic"
            onTriggered: root.toggleFavorite(friendMenu.friend.steamid)
        }
    }
    function popMenu(f) { friendMenu.friend = f; friendMenu.popup() }

    // ---- panel (compact) icon, with an online-count badge ----
    compactRepresentation: MouseArea {
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            anchors.fill: parent
            source: root.panelIcon
            active: parent.containsMouse
        }
        Rectangle {
            visible: Plasmoid.configuration.showCountBadge && root.onlineCount > 0
            anchors.right: parent.right; anchors.bottom: parent.bottom
            height: Math.round(Math.min(parent.width, parent.height) * 0.5)
            width: Math.max(height, badgeLabel.implicitWidth + height * 0.4)
            radius: height / 2
            color: root.cInGame
            PlasmaComponents.Label {
                id: badgeLabel
                anchors.centerIn: parent
                text: root.onlineCount
                color: "white"; font.bold: true
                font.pixelSize: Math.round(parent.height * 0.72)
            }
        }
    }

    // ---- popup (full) representation ----
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 13
        Layout.minimumHeight: Kirigami.Units.gridUnit * 10
        implicitWidth: Kirigami.Units.gridUnit * 18
        implicitHeight: Kirigami.Units.gridUnit * 26

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // ---- top bar: search + sort/filter dropdown (App Portal style) ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                QQC2.TextField {
                    id: searchField
                    Layout.fillWidth: true
                    placeholderText: i18n("Search…")
                    text: root.searchText
                    onTextChanged: root.searchText = text
                    QQC2.ToolButton {
                        visible: searchField.text !== ""
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        flat: true; icon.name: "edit-clear"
                        onClicked: searchField.clear()
                    }
                }

                // sort + filter dropdown (icon only), like the App Portal
                QQC2.ToolButton {
                    icon.name: root.sortMode === "name_desc" ? "view-sort-descending" : "view-sort-ascending"
                    onClicked: sortMenu.popup()
                    QQC2.ToolTip.text: i18n("Sort & filter"); QQC2.ToolTip.visible: hovered
                    QQC2.Menu {
                        id: sortMenu
                        QQC2.MenuItem {
                            text: i18n("Name (A–Z)"); icon.name: "view-sort-ascending"
                            checkable: true; checked: root.sortMode === "name"
                            onTriggered: { root.sortMode = "name"; Plasmoid.configuration.sortMode = "name" }
                        }
                        QQC2.MenuItem {
                            text: i18n("Name (Z–A)"); icon.name: "view-sort-descending"
                            checkable: true; checked: root.sortMode === "name_desc"
                            onTriggered: { root.sortMode = "name_desc"; Plasmoid.configuration.sortMode = "name_desc" }
                        }
                        QQC2.MenuSeparator {}
                        QQC2.MenuItem {
                            text: i18n("Hide offline"); icon.name: "im-invisible-user"
                            checkable: true; checked: root.hideOffline
                            onTriggered: { root.hideOffline = checked; Plasmoid.configuration.hideOffline = checked }
                        }
                        QQC2.MenuSeparator {}
                        QQC2.MenuItem {
                            text: i18n("Refresh"); icon.name: "view-refresh"
                            onTriggered: root.read()
                        }
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // ---- friends list ----
            ListView {
                id: listView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                reuseItems: true
                cacheBuffer: Kirigami.Units.gridUnit * 20
                model: rowModel
                spacing: 1
                boundsBehavior: Flickable.StopAtBounds
                QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

                // ---- clear section headers, with a separator (like All Applications) ----
                section.property: "section"
                section.criteria: ViewSection.FullString
                section.delegate: ColumnLayout {
                    width: ListView.view ? ListView.view.width : 0
                    spacing: Kirigami.Units.smallSpacing / 2
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.smallSpacing
                        Layout.topMargin: Kirigami.Units.smallSpacing / 2
                        text: section
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        font.bold: true
                        opacity: 0.6
                    }
                    Kirigami.Separator { Layout.fillWidth: true }
                }

                delegate: Rectangle {
                    id: rowItem
                    required property string steamid
                    required property bool fav
                    // friend data looked up live -> updates in place when byId refreshes,
                    // without recreating the delegate
                    readonly property var f: root.friendsById[steamid] || ({})
                    readonly property bool dim: !f.ingame && f.state === 0
                    width: ListView.view ? ListView.view.width : 0
                    height: Math.max(Kirigami.Units.gridUnit * 2.2,
                                     Plasmoid.configuration.avatarSize + Kirigami.Units.smallSpacing * 2)
                    radius: Kirigami.Units.smallSpacing
                    color: rowHover.hovered
                        ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                                  Kirigami.Theme.highlightColor.b, 0.18)
                        : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Kirigami.Units.smallSpacing
                        anchors.rightMargin: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing

                        // avatar with a presence-coloured ring
                        Item {
                            Layout.preferredWidth: Plasmoid.configuration.avatarSize
                            Layout.preferredHeight: Plasmoid.configuration.avatarSize
                            Rectangle {
                                anchors.fill: parent
                                radius: Kirigami.Units.smallSpacing / 2
                                color: "transparent"
                                border.width: 2
                                border.color: root.stateColor(rowItem.f)
                            }
                            Image {
                                id: avatarImg
                                anchors.fill: parent
                                anchors.margins: 2
                                source: rowItem.f.avatar || ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true; cache: true
                                opacity: rowItem.dim ? 0.5 : 1.0
                            }
                            Kirigami.Icon {
                                anchors.fill: parent
                                anchors.margins: 2
                                visible: avatarImg.status !== Image.Ready
                                source: "im-user"
                                opacity: rowItem.dim ? 0.5 : 1.0
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing / 2
                                Kirigami.Icon {
                                    visible: rowItem.fav
                                    source: "starred-symbolic"
                                    color: "#f0b400"
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                }
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: rowItem.f.name || ""
                                    elide: Text.ElideRight
                                    font.weight: Font.DemiBold
                                    opacity: rowItem.dim ? 0.6 : 1.0
                                    color: rowItem.f.ingame ? root.cInGame : Kirigami.Theme.textColor
                                }
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                text: root.stateText(rowItem.f)
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                color: rowItem.f.ingame ? root.cInGame : Kirigami.Theme.textColor
                            }
                        }

                        // right side: game art (in-game), else flag + last-online
                        Image {
                            visible: !!(rowItem.f.ingame && rowItem.f.capsule)
                            source: visible ? rowItem.f.capsule : ""
                            Layout.preferredHeight: Plasmoid.configuration.avatarSize * 0.62
                            Layout.preferredWidth: Layout.preferredHeight * (184 / 69)
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true; cache: true
                        }
                        ColumnLayout {
                            readonly property string flag: root.flagEmoji(rowItem.f.country)
                            readonly property string ago: root.lastOnlineText(rowItem.f)
                            visible: !rowItem.f.ingame && (flag !== "" || ago !== "")
                            spacing: 0
                            PlasmaComponents.Label {
                                Layout.alignment: Qt.AlignRight
                                visible: parent.flag !== ""
                                text: parent.flag
                                font.family: "Noto Color Emoji"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                            PlasmaComponents.Label {
                                Layout.alignment: Qt.AlignRight
                                visible: parent.ago !== ""
                                text: parent.ago
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: 0.55
                            }
                        }
                    }

                    HoverHandler { id: rowHover }
                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onTapped: root.steamRun(rowItem.f.chat)
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: root.popMenu(rowItem.f)
                    }
                }
            }
        }

        // empty hint sits over the list area
        PlasmaComponents.Label {
            anchors.centerIn: parent
            visible: root.error === "" && rowModel.count === 0
            text: root.searchText !== "" ? i18n("No matches")
                : root.hideOffline ? i18n("No friends online")
                : i18n("No friends to show")
            opacity: 0.5
        }

        // ---- setup / error overlay: shown when the collector can't authenticate ----
        Rectangle {
            id: setupOverlay
            anchors.fill: parent
            z: 100
            visible: root.error !== ""
            color: Qt.alpha(Kirigami.Theme.backgroundColor, 0.96)
            radius: Kirigami.Units.smallSpacing
            MouseArea { anchors.fill: parent }   // swallow clicks to the list below

            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width - Kirigami.Units.largeSpacing * 2
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: Kirigami.Units.iconSizes.large
                    Layout.preferredHeight: Kirigami.Units.iconSizes.large
                    source: "dialog-password"
                    opacity: 0.8
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    font.weight: Font.DemiBold
                    text: i18n("Steam Web API key needed")
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    opacity: 0.7
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    text: i18n("The friends collector couldn't authenticate:\n%1", root.error)
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    textFormat: Text.StyledText
                    text: i18n('Get a free key at <a href="https://steamcommunity.com/dev/apikey">steamcommunity.com/dev/apikey</a>')
                    onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.TextField {
                        id: keyField
                        Layout.fillWidth: true
                        placeholderText: i18n("Paste your API key")
                        enabled: !root.saving
                        onAccepted: root.saveKey(text)
                    }
                    QQC2.Button {
                        text: root.saving ? i18n("Saving…") : i18n("Save")
                        enabled: !root.saving && keyField.text !== ""
                        icon.name: "dialog-ok-apply"
                        onClicked: root.saveKey(keyField.text)
                    }
                }
            }
        }
    }
}
