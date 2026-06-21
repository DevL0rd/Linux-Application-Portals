/*
 * App view for a kicker AbstractModel (favourites or a category). Grid or list,
 * with search + sort (incl. last-opened). Launches and shows native right-click
 * actions via the original model row, plus a direct Add/Remove Favourite item
 * wired to the shared favourites model.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid

Item {
    id: root
    property var appModel: null
    property var favSet: ({})               // desktop-id -> true
    property bool excludeFavorites: false   // hide favourites (they're pinned elsewhere)
    property string viewMode: "grid"       // grid | list
    property string searchText: ""
    property string sortMode: "recent"
    property var usage: ({})
    signal launchedKey(string key)
    signal favToggle(string resource, bool add)
    function favKey(id) { return String(id || "").replace(/^applications:/, "") }

    readonly property int iconSize: Plasmoid.configuration.iconSize

    property var rawItems: []
    function rebuild() {
        var arr = []
        for (var i = 0; i < inst.count; i++) {
            var o = inst.objectAt(i)
            if (o) arr.push({ row: o.row, name: o.name, icon: o.icon, url: o.url,
                              favoriteId: o.favoriteId, hasActionList: o.hasActionList, actionList: o.actionList })
        }
        root.rawItems = arr
    }
    Instantiator {
        id: inst
        model: root.appModel
        delegate: QtObject {
            required property var model
            required property int index
            readonly property int row: index
            readonly property string name: model.display || ""
            readonly property var icon: model.decoration
            readonly property string url: model.url || ""
            readonly property string favoriteId: model.favoriteId || ""
            readonly property bool hasActionList: model.hasActionList || false
            readonly property var actionList: model.hasActionList ? model.actionList : []
        }
        onObjectAdded: root.rebuild()
        onObjectRemoved: root.rebuild()
    }
    onAppModelChanged: rebuild()

    readonly property var items: {
        var q = root.searchText.toLowerCase()
        var a = root.rawItems.filter(function(it) {
            // on the All Applications page favourites are pinned in their own strip,
            // so drop them here to avoid showing each one twice
            if (root.excludeFavorites && it.favoriteId && root.favSet[root.favKey(it.favoriteId)]) return false
            return q === "" || it.name.toLowerCase().indexOf(q) >= 0
        })
        a = a.slice()
        if (root.sortMode === "name")
            a.sort(function(x, y) { return x.name.localeCompare(y.name) })
        else if (root.sortMode === "name_desc")
            a.sort(function(x, y) { return y.name.localeCompare(x.name) })
        else
            a.sort(function(x, y) {
                var d = (root.usage[y.url] || 0) - (root.usage[x.url] || 0)
                return d !== 0 ? d : x.name.localeCompare(y.name)
            })
        return a
    }

    function activate(it) {
        if (root.appModel && root.appModel.trigger(it.row, "", null))
            root.launchedKey(it.url)
    }
    function openMenu(it) {
        ctxMenu.it = it
        ctxMenu.actions = (it.actionList || []).filter(function(a) {
            return a && !a.separator && (a.actionId === undefined || String(a.actionId).indexOf("favorite") < 0)
        })
        ctxMenu.popup()
    }

    // ---------------- GRID ----------------
    GridView {
        id: grid
        // centered: fixed-size cells, grid width snapped to the columns actually used
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: cols * cellWidth
        visible: root.viewMode === "grid"
        clip: true
        model: root.viewMode === "grid" ? root.items : []
        readonly property int cell: root.iconSize + Kirigami.Units.gridUnit * 2
        readonly property int maxCols: Math.max(1, Math.floor(root.width / cell))
        readonly property int cols: Math.max(1, Math.min(count, maxCols))
        cellWidth: cell
        cellHeight: root.iconSize + (Plasmoid.configuration.showAppLabels ? Kirigami.Units.gridUnit * 2.4 : Kirigami.Units.smallSpacing * 3)
        boundsBehavior: Flickable.StopAtBounds
        QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

        delegate: Item {
            width: grid.cellWidth
            height: grid.cellHeight
            Rectangle {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing / 2
                radius: Kirigami.Units.smallSpacing
                color: cellMa.containsMouse ? Qt.alpha(Kirigami.Theme.highlightColor, 0.2) : "transparent"
            }
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing / 2
                Kirigami.Icon {
                    source: modelData.icon
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: root.iconSize
                    Layout.preferredHeight: root.iconSize
                }
                PlasmaComponents.Label {
                    visible: Plasmoid.configuration.showAppLabels
                    text: modelData.name
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.Wrap
                    font: Kirigami.Theme.smallFont
                }
            }
            MouseArea {
                id: cellMa
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(m) { if (m.button === Qt.RightButton) root.openMenu(modelData) }
                onDoubleClicked: function(m) { if (m.button === Qt.LeftButton) root.activate(modelData) }
            }
        }
    }

    // ---------------- LIST ----------------
    ListView {
        id: list
        anchors.fill: parent
        visible: root.viewMode === "list"
        clip: true
        model: root.viewMode === "list" ? root.items : []
        boundsBehavior: Flickable.StopAtBounds
        QQC2.ScrollBar.vertical: QQC2.ScrollBar {}

        delegate: Rectangle {
            width: list.width
            height: root.iconSize * 0.8 + Kirigami.Units.smallSpacing * 2
            radius: Kirigami.Units.smallSpacing
            color: rowMa.containsMouse ? Qt.alpha(Kirigami.Theme.highlightColor, 0.18) : "transparent"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Kirigami.Units.smallSpacing
                anchors.rightMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Icon {
                    source: modelData.icon
                    Layout.preferredWidth: root.iconSize * 0.8
                    Layout.preferredHeight: root.iconSize * 0.8
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: modelData.name
                    elide: Text.ElideRight
                }
            }
            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(m) { if (m.button === Qt.RightButton) root.openMenu(modelData) }
                onDoubleClicked: function(m) { if (m.button === Qt.LeftButton) root.activate(modelData) }
            }
        }
    }

    // shared context menu: favourite toggle + the entry's native actions
    QQC2.Menu {
        id: ctxMenu
        property var it: null
        property var actions: []
        QQC2.MenuItem {
            visible: ctxMenu.it && ctxMenu.it.favoriteId !== ""
            height: visible ? implicitHeight : 0
            icon.name: "favorite"
            text: (ctxMenu.it && root.favSet[root.favKey(ctxMenu.it.favoriteId)])
                  ? i18n("Remove from Favourites") : i18n("Add to Favourites")
            onTriggered: {
                if (!ctxMenu.it) return
                var isFav = root.favSet[root.favKey(ctxMenu.it.favoriteId)] === true
                root.favToggle(ctxMenu.it.favoriteId, !isFav)
            }
        }
        QQC2.MenuSeparator { visible: ctxMenu.it && ctxMenu.it.favoriteId !== "" }
        Instantiator {
            model: ctxMenu.actions
            delegate: QQC2.MenuItem {
                required property var modelData
                text: modelData.text || ""
                icon.name: modelData.icon || ""
                onTriggered: {
                    if (ctxMenu.it)
                        root.appModel.trigger(ctxMenu.it.row, modelData.actionId || "",
                                              modelData.actionArgument === undefined ? null : modelData.actionArgument)
                    root.launchedKey(ctxMenu.it ? ctxMenu.it.url : "")
                }
            }
            onObjectAdded: function(index, object) { ctxMenu.addItem(object) }
            onObjectRemoved: function(index, object) { ctxMenu.removeItem(object) }
        }
    }

    PlasmaComponents.Label {
        anchors.centerIn: parent
        visible: root.items.length === 0
        text: root.searchText !== "" ? i18n("No matches") : i18n("Nothing here")
        opacity: 0.5
    }
}
