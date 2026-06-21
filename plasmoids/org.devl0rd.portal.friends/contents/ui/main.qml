/*
 * Plasma-App-Portal :: Steam Friends
 * A friends-list popup that mirrors the App Portal look: a search field plus a
 * sort/filter dropdown in the top bar, then a live list of friends with avatars,
 * presence (in-game / online / away / offline) and a right-click action menu.
 * Presence comes from the shared `portal-friends` collector (Steam Web API),
 * which the App Portal already runs as a resident service. "Favourites" are our
 * own per-instance pins (Steam doesn't expose its favourites), sorted to the top.
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
    property var friends: []
    property string error: ""
    property bool saving: false
    property string searchText: ""
    // toolbar state is per-applet-instance (persisted), like the App Portal
    property string sortMode: Plasmoid.configuration.sortMode      // status|name|name_desc
    property bool hideOffline: Plasmoid.configuration.hideOffline

    readonly property string bin: "$HOME/.local/bin/portal-friends --snapshot"
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // ---- favourites (our own; comma-separated steamids in config) ----
    function favoritesList() {
        return (Plasmoid.configuration.favorites || "").split(",").filter(function(s) { return s !== "" })
    }
    function isFavorite(sid) { return favoritesList().indexOf(String(sid)) >= 0 }
    function toggleFavorite(sid) {
        sid = String(sid)
        var l = favoritesList(); var i = l.indexOf(sid)
        if (i >= 0) l.splice(i, 1); else l.push(sid)
        Plasmoid.configuration.favorites = l.join(",")
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

    // ---- search + filter, grouped into sections, sorted by name within each ----
    readonly property var view: {
        var q = root.searchText.toLowerCase()
        var favs = root.favoritesList()
        var dir = root.sortMode === "name_desc" ? -1 : 1
        var a = (root.friends || []).filter(function(f) {
            if (root.hideOffline && !f.ingame && f.state === 0) return false
            if (q !== "" && (f.name || "").toLowerCase().indexOf(q) < 0) return false
            return true
        })
        var mapped = a.map(function(f) {
            var fav = favs.indexOf(String(f.steamid)) >= 0
            var o = Object.assign({}, f)
            o._fav = fav
            o._section = root.sectionOf(f, fav)
            o._rank = root.sectionRank(f, fav)
            return o
        })
        mapped.sort(function(x, y) {
            if (x._rank !== y._rank) return x._rank - y._rank
            return dir * (x.name || "").localeCompare(y.name || "")
        })
        return mapped
    }

    readonly property var sortOptions: [
        { id: "name", label: i18n("Name (A–Z)"), icon: "view-sort-ascending" },
        { id: "name_desc", label: i18n("Name (Z–A)"), icon: "view-sort-descending" }
    ]
    function iconFor(opts, id, fallback) {
        for (var i = 0; i < opts.length; i++) if (opts[i].id === id) return opts[i].icon
        return fallback
    }

    // ---- data: read the cached snapshot the resident collector writes ----
    P5Support.DataSource {
        id: src
        engine: "executable"
        onNewData: function(source, d) {
            disconnectSource(source)
            try {
                var s = JSON.parse(d.stdout || "{}")
                root.friends = s.friends || []
                root.error = (s.ok === false) ? (s.error || i18n("No data")) : ""
            } catch (e) { root.error = i18n("Could not read friends data") }
            root.saving = false
        }
    }
    function reload() { src.connectSource(root.bin) }

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
    Timer { id: setupReloadTimer; interval: 4000; repeat: false; onTriggered: root.reload() }

    // poll the (cheap, local) snapshot file; the collector refreshes it every 10s
    Timer { interval: 5000; repeat: true; running: true; onTriggered: root.reload() }
    Component.onCompleted: { refreshIcon(); reload() }
    onExpandedChanged: if (expanded) reload()

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
                    icon.name: root.iconFor(root.sortOptions, root.sortMode, "view-sort")
                    onClicked: sortMenu.popup()
                    QQC2.ToolTip.text: i18n("Sort & filter"); QQC2.ToolTip.visible: hovered
                    QQC2.Menu {
                        id: sortMenu
                        Repeater {
                            model: root.sortOptions
                            delegate: QQC2.MenuItem {
                                required property var modelData
                                text: modelData.label
                                icon.name: modelData.icon
                                checkable: true
                                checked: root.sortMode === modelData.id
                                onTriggered: {
                                    root.sortMode = modelData.id
                                    Plasmoid.configuration.sortMode = modelData.id
                                }
                            }
                        }
                        // ---- additive filter, separate from sorting ----
                        QQC2.MenuSeparator {}
                        QQC2.MenuItem {
                            text: i18n("Hide offline")
                            icon.name: "im-invisible-user"
                            checkable: true
                            checked: root.hideOffline
                            onTriggered: {
                                root.hideOffline = checked
                                Plasmoid.configuration.hideOffline = checked
                            }
                        }
                        QQC2.MenuSeparator {}
                        QQC2.MenuItem {
                            text: i18n("Refresh")
                            icon.name: "view-refresh"
                            onTriggered: root.reload()
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
                model: root.view
                spacing: 1
                boundsBehavior: Flickable.StopAtBounds
                QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

                // ---- clear section headers (Favourites / In Game / Online / Offline) ----
                section.property: "_section"
                section.criteria: ViewSection.FullString
                section.delegate: Item {
                    width: ListView.view ? ListView.view.width : 0
                    height: secLabel.implicitHeight + Kirigami.Units.smallSpacing * 1.5
                    PlasmaComponents.Label {
                        id: secLabel
                        anchors.left: parent.left
                        anchors.leftMargin: Kirigami.Units.smallSpacing
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Kirigami.Units.smallSpacing / 2
                        text: section
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        font.bold: true
                        opacity: 0.6
                    }
                }

                delegate: Rectangle {
                    id: rowItem
                    required property var modelData
                    width: ListView.view ? ListView.view.width : 0
                    height: Math.max(Kirigami.Units.gridUnit * 2.2,
                                     Plasmoid.configuration.avatarSize + Kirigami.Units.smallSpacing * 2)
                    radius: Kirigami.Units.smallSpacing
                    readonly property bool dim: !modelData.ingame && modelData.state === 0
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
                                border.color: root.stateColor(rowItem.modelData)
                            }
                            Image {
                                id: avatarImg
                                anchors.fill: parent
                                anchors.margins: 2
                                source: rowItem.modelData.avatar || ""
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
                                    visible: rowItem.modelData._fav === true
                                    source: "starred-symbolic"
                                    color: "#f0b400"
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                }
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: rowItem.modelData.name || ""
                                    elide: Text.ElideRight
                                    font.weight: Font.DemiBold
                                    opacity: rowItem.dim ? 0.6 : 1.0
                                    color: rowItem.modelData.ingame ? root.cInGame : Kirigami.Theme.textColor
                                }
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                text: root.stateText(rowItem.modelData)
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                color: rowItem.modelData.ingame ? root.cInGame : Kirigami.Theme.textColor
                            }
                        }
                    }

                    HoverHandler { id: rowHover }
                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onTapped: root.steamRun(rowItem.modelData.chat)
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: root.popMenu(rowItem.modelData)
                    }
                }
            }

            // ---- states ----
            PlasmaComponents.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                visible: root.error !== ""
                text: root.error
                opacity: 0.6
                wrapMode: Text.Wrap
            }
        }

        // empty hint sits over the list area
        PlasmaComponents.Label {
            anchors.centerIn: parent
            visible: root.error === "" && root.view.length === 0
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
