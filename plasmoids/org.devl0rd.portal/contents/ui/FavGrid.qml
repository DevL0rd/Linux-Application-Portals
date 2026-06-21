/*
 * Favourites view, fed by the backend which reads the shared KActivities store
 * (the same favourites as Plasma's start menu). Plain JSON -> icons; launches via
 * the resolved Exec; right-click removes the favourite. Grid or list, and a
 * "section mode" that sizes to content (non-scrolling) for stacking on the
 * All Applications page.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

Item {
    id: root
    property var favorites: []
    property string searchText: ""
    property string viewMode: "grid"        // grid | list
    property bool sectionMode: false        // size to content, no own scroll
    signal launched()
    signal removeFav(string resource)

    readonly property int iconSize: Plasmoid.configuration.iconSize

    // metrics derived from config + width only (never the view's own height) so a
    // caller can size a section without creating a layout binding loop
    readonly property int cellW: iconSize + Kirigami.Units.gridUnit * 2
    readonly property int rowHeight: iconSize + (Plasmoid.configuration.showAppLabels ? Kirigami.Units.gridUnit * 2.4 : Kirigami.Units.smallSpacing * 3)
    readonly property int listRowHeight: Math.round(iconSize * 0.8) + Kirigami.Units.smallSpacing * 2
    readonly property int maxCols: Math.max(1, Math.floor(width / cellW))
    readonly property int contentHeightHint: {
        var n = items.length
        if (n === 0) return 0
        if (viewMode === "list") return n * listRowHeight
        var cols = Math.max(1, Math.min(n, maxCols))
        return Math.ceil(n / cols) * rowHeight
    }

    readonly property var items: {
        var q = root.searchText.toLowerCase()
        return (root.favorites || []).filter(function(f) {
            return q === "" || (f.name || "").toLowerCase().indexOf(q) >= 0
        })
    }

    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    function activate(f) { if (f && f.launch) { runner.connectSource(f.launch); root.launched() } }

    // ---------------- GRID (centered) ----------------
    GridView {
        id: grid
        visible: root.viewMode === "grid"
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: cols * cellWidth
        clip: true
        interactive: !root.sectionMode
        model: root.viewMode === "grid" ? root.items : []
        readonly property int cols: Math.max(1, Math.min(count, root.maxCols))
        cellWidth: root.cellW
        cellHeight: root.rowHeight
        boundsBehavior: Flickable.StopAtBounds
        QQC2.ScrollBar.vertical: QQC2.ScrollBar { visible: !root.sectionMode }

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
                    source: modelData.icon || "application-x-executable"
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: root.iconSize
                    Layout.preferredHeight: root.iconSize
                }
                PlasmaComponents.Label {
                    visible: Plasmoid.configuration.showAppLabels
                    text: modelData.name || ""
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
                onClicked: function(m) { if (m.button === Qt.RightButton) { favMenu.fav = modelData; favMenu.popup() } }
                onDoubleClicked: function(m) { if (m.button === Qt.LeftButton) root.activate(modelData) }
            }
        }
    }

    // ---------------- LIST ----------------
    ListView {
        id: list
        visible: root.viewMode === "list"
        anchors.fill: parent
        clip: true
        interactive: !root.sectionMode
        model: root.viewMode === "list" ? root.items : []
        boundsBehavior: Flickable.StopAtBounds
        QQC2.ScrollBar.vertical: QQC2.ScrollBar { visible: !root.sectionMode }

        delegate: Rectangle {
            width: list.width
            height: root.listRowHeight
            radius: Kirigami.Units.smallSpacing
            color: rowMa.containsMouse ? Qt.alpha(Kirigami.Theme.highlightColor, 0.18) : "transparent"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Kirigami.Units.smallSpacing
                anchors.rightMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Icon {
                    source: modelData.icon || "application-x-executable"
                    Layout.preferredWidth: root.iconSize * 0.8
                    Layout.preferredHeight: root.iconSize * 0.8
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: modelData.name || ""
                    elide: Text.ElideRight
                }
            }
            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(m) { if (m.button === Qt.RightButton) { favMenu.fav = modelData; favMenu.popup() } }
                onDoubleClicked: function(m) { if (m.button === Qt.LeftButton) root.activate(modelData) }
            }
        }
    }

    QQC2.Menu {
        id: favMenu
        property var fav: null
        QQC2.MenuItem { text: i18n("Launch"); icon.name: "media-playback-start"; enabled: favMenu.fav && favMenu.fav.launch; onTriggered: root.activate(favMenu.fav) }
        QQC2.MenuSeparator {}
        QQC2.MenuItem {
            text: i18n("Remove from Favourites"); icon.name: "list-remove"
            onTriggered: if (favMenu.fav) root.removeFav(favMenu.fav.resource)
        }
    }

    PlasmaComponents.Label {
        anchors.centerIn: parent
        visible: !root.sectionMode && root.items.length === 0
        text: root.searchText !== "" ? i18n("No matches") : i18n("No favourites yet")
        opacity: 0.5
    }
}
