/*
 * Favourites grid, fed by the backend which reads the shared KActivities store
 * (the same favourites as Plasma's start menu). Plain JSON -> icons; launches via
 * the resolved Exec; right-click removes the favourite.
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
    signal launched()
    signal removeFav(string resource)
    signal zoomReady()                 // (kept for symmetry; zoom handled by overlay)

    readonly property int iconSize: Plasmoid.configuration.iconSize

    // height hints so callers can cap the view (e.g. the All Applications strip)
    readonly property real gridContentHeight: grid.contentHeight
    readonly property int rowHeight: grid.cellHeight

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

    GridView {
        id: grid
        // centered: fixed-size cells, grid width snapped to the columns actually used
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: cols * cellWidth
        clip: true
        model: root.items
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
        visible: root.items.length === 0
        text: root.searchText !== "" ? i18n("No matches") : i18n("No favourites yet")
        opacity: 0.5
    }
}
