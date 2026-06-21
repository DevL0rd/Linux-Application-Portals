/*
 * Plasma-App-Portal :: main
 * A launcher popup with a category dropdown (Favorites / All / Development / ...
 * driven by the same kicker models Plasma's own launcher uses, so categories,
 * favourites, right-click actions and live updates come for free) plus a special,
 * art-rich Games view. Every page supports search + sorting; "last opened" is
 * tracked locally for whatever you launch through the portal.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.private.kicker as Kicker

PlasmoidItem {
    id: root

    // bind to a local string (never undefined) instead of straight to config,
    // which is briefly null during init
    property string panelIcon: "applications-all"
    function refreshIcon() { panelIcon = (Plasmoid.configuration.icon || "applications-all") }
    Plasmoid.icon: root.panelIcon
    Plasmoid.title: i18n("App Portal")
    Connections { target: Plasmoid.configuration; function onIconChanged() { root.refreshIcon() } }

    // categories: [{label, type:"fav"|"apps"|"games", row}]
    property var categories: []
    // the selected tab is tracked by LABEL (persisted), and the index is DERIVED
    // from it -- so when the kicker categories reload, the selection can't be reset
    property string selectedLabel: "Favorites"
    function indexOfLabel(lbl) {
        for (var i = 0; i < categories.length; i++)
            if (categories[i].label === lbl) return i
        return 0
    }
    readonly property int currentIndex: indexOfLabel(selectedLabel)
    readonly property var currentCat: (currentIndex >= 0 && currentIndex < categories.length)
        ? categories[currentIndex] : null
    readonly property bool gamesActive: currentCat && currentCat.type === "games"
    readonly property bool favActive: currentCat && currentCat.type === "fav"
    // the "All Applications" page gets a pinned Favourites section at the top
    readonly property bool allAppsActive: currentCat && currentCat.type === "apps" && currentCat.allApps === true

    // favourites read from the shared KActivities store via the backend
    property var favorites: []
    property var favSet: ({})       // desktop-id -> true, for quick "is favourite?"
    function favKey(id) { return String(id || "").replace(/^applications:/, "") }

    property string sortMode: "recent"                             // recent|name|name_desc
    property string searchText: ""
    property var usage: ({})                                        // launch key -> epoch

    readonly property string portalBin: "$HOME/.local/bin/portal-games"
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    function appModelFor(cat) {
        if (!cat) return null
        if (cat.type === "apps") return rootModel.modelForRow(cat.row)
        return null
    }

    // ---- favourites (backend-backed, no kicker model) ----
    P5Support.DataSource {
        id: favSrc
        engine: "executable"
        onNewData: function(source, d) {
            disconnectSource(source)
            var list = []
            try { list = JSON.parse(d.stdout || "{}").favorites || [] } catch (e) {}
            root.favorites = list
            var s = {}
            for (var i = 0; i < list.length; i++) s[root.favKey(list[i].id)] = true
            root.favSet = s
        }
    }
    function loadFavorites() { favSrc.connectSource(portalBin + " --favorites") }
    // the Favourites tab AND the All Applications page (pinned favourites strip) both
    // need a fresh snapshot when shown
    onCurrentIndexChanged: if (favActive || allAppsActive) loadFavorites()
    // favourites come from a backend snapshot (not a live model like the kicker app
    // models), so refresh them while a page that displays them is on screen
    Timer {
        interval: 2500
        repeat: true
        running: root.favActive || root.allAppsActive
        onTriggered: root.loadFavorites()
    }
    P5Support.DataSource {
        id: favWriter
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source); root.loadFavorites() }
    }
    function toggleFavorite(resource, add) {
        favWriter.connectSource(portalBin + (add ? " --fav-add " : " --fav-remove ") + shq(resource))
    }

    // Ctrl+scroll zoom -> adjusts the active page's item size (per-instance config)
    function zoom(step) {
        if (root.gamesActive)
            Plasmoid.configuration.gameCardWidth =
                Math.max(100, Math.min(320, Plasmoid.configuration.gameCardWidth + step * 12))
        else
            Plasmoid.configuration.iconSize =
                Math.max(32, Math.min(160, Plasmoid.configuration.iconSize + step * 8))
    }

    // ---- usage (last-opened) tracking ----
    P5Support.DataSource {
        id: usageSrc
        engine: "executable"
        onNewData: function(source, d) {
            disconnectSource(source)
            try { root.usage = JSON.parse(d.stdout || "{}") } catch (e) { root.usage = ({}) }
        }
    }
    P5Support.DataSource {
        id: tracker
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    function loadUsage() { usageSrc.connectSource(portalBin + " --usage") }
    function recordLaunch(key) { if (key) tracker.connectSource(portalBin + " --track " + shq(key)) }

    onExpandedChanged: if (root.expanded) { loadUsage(); loadFavorites() }
    Component.onCompleted: {
        refreshIcon()
        selectedLabel = Plasmoid.configuration.defaultCategory || "Favorites"
        sortMode = Plasmoid.configuration.defaultSort || "recent"
        appViewMode = Plasmoid.configuration.appViewMode || "grid"
        loadUsage()
        loadFavorites()
    }

    // ---- the kicker app/category source ----
    Kicker.RootModel {
        id: rootModel
        autoPopulate: true
        appletInterface: root
        flat: false
        sorted: true
        showSeparators: false
        appNameFormat: 0
        showAllApps: true
        showAllAppsCategorized: false
        showRecentApps: false
        showRecentDocs: false
        showPowerSession: false
        onCountChanged: root.rebuildCategories()
        Component.onCompleted: root.rebuildCategories()
    }

    Instantiator {
        id: catRows
        model: rootModel
        delegate: QtObject {
            required property var model
            required property int index
            readonly property string label: model.display || ""
            readonly property int row: index
        }
        onObjectAdded: root.rebuildCategories()
        onObjectRemoved: root.rebuildCategories()
    }

    function rebuildCategories() {
        var cats = [{ label: i18n("Favorites"), type: "fav", row: -1 }]
        var hadGames = false
        // the kicker emits "All Applications" as its first app category (showAllApps,
        // not categorized); flag the first apps entry so it gets the favourites strip,
        // instead of matching a localised label
        var assignedAll = false
        for (var i = 0; i < catRows.count; i++) {
            var o = catRows.objectAt(i)
            if (!o || o.label === "") continue
            if (o.label.toLowerCase().indexOf("game") >= 0) {
                cats.push({ label: o.label, type: "games", row: o.row }); hadGames = true
            } else {
                var isAll = !assignedAll
                if (isAll) assignedAll = true
                cats.push({ label: o.label, type: "apps", row: o.row, allApps: isAll })
            }
        }
        if (!hadGames)
            cats.push({ label: i18n("Games"), type: "games", row: -1 })
        root.categories = cats
        // currentIndex is derived from selectedLabel, so it follows automatically
        // once the saved category appears in the list -- nothing to restore here.
    }

    // clear the search on launch so the list is back to normal next time it opens
    function launchAndClose() { root.searchText = ""; root.expanded = false }

    // sort metadata shared by the sort dropdown
    readonly property var sortOptions: [
        { id: "recent", label: i18n("Last opened"), icon: "appointment-recurring" },
        { id: "name", label: i18n("Name (A–Z)"), icon: "view-sort-ascending" },
        { id: "name_desc", label: i18n("Name (Z–A)"), icon: "view-sort-descending" }
    ]
    // games get all of these; non-game pages get the non-art views only
    readonly property var gameViewOptions: [
        { id: "grid", label: i18n("Grid"), icon: "view-list-icons" },
        { id: "list", label: i18n("List"), icon: "view-list-details" },
        { id: "carousel", label: i18n("Shelf"), icon: "view-media-playlist" },
        { id: "carousel3d", label: i18n("Carousel"), icon: "view-presentation" },
        { id: "banner", label: i18n("Banners"), icon: "view-preview" }
    ]
    readonly property var appViewOptions: [
        { id: "grid", label: i18n("Grid"), icon: "view-list-icons" },
        { id: "list", label: i18n("List"), icon: "view-list-details" }
    ]
    property string appViewMode: "grid"
    readonly property var viewOptions: gamesActive ? gameViewOptions : appViewOptions
    readonly property string currentViewMode: gamesActive ? Plasmoid.configuration.gamesViewMode : appViewMode
    function setViewMode(id) {
        if (gamesActive) Plasmoid.configuration.gamesViewMode = id
        else { appViewMode = id; Plasmoid.configuration.appViewMode = id }
    }
    function iconFor(opts, id, fallback) {
        for (var i = 0; i < opts.length; i++) if (opts[i].id === id) return opts[i].icon
        return fallback
    }

    preferredRepresentation: fullRepresentation

    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 8
        implicitWidth: Kirigami.Units.gridUnit * 36
        implicitHeight: Kirigami.Units.gridUnit * 26

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // ---- top bar ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                QQC2.ComboBox {
                    id: catCombo
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 10
                    model: root.categories
                    textRole: "label"
                    // the combo resets its own currentIndex when the model reloads, so
                    // re-assert it from the derived index instead of binding
                    Component.onCompleted: currentIndex = root.currentIndex
                    onModelChanged: currentIndex = root.currentIndex
                    Connections {
                        target: root
                        function onCurrentIndexChanged() { catCombo.currentIndex = root.currentIndex }
                    }
                    onActivated: {
                        if (root.categories[currentIndex]) {   // remember the tab (per-instance, by label)
                            root.selectedLabel = root.categories[currentIndex].label
                            Plasmoid.configuration.defaultCategory = root.selectedLabel
                            Plasmoid.configuration.writeConfig()
                        }
                    }
                }

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

                // sort dropdown (icon only)
                QQC2.ToolButton {
                    icon.name: root.iconFor(root.sortOptions, root.sortMode, "view-sort")
                    onClicked: sortMenu.popup()
                    QQC2.ToolTip.text: i18n("Sort"); QQC2.ToolTip.visible: hovered
                    QQC2.Menu {
                        id: sortMenu
                        Instantiator {
                            model: root.sortOptions
                            delegate: QQC2.MenuItem {
                                required property var modelData
                                text: modelData.label
                                icon.name: modelData.icon
                                checkable: true
                                checked: root.sortMode === modelData.id
                                onTriggered: {
                                    root.sortMode = modelData.id
                                    Plasmoid.configuration.defaultSort = modelData.id
                                }
                            }
                            onObjectAdded: function(i, o) { sortMenu.insertItem(i, o) }
                            onObjectRemoved: function(i, o) { sortMenu.removeItem(o) }
                        }
                    }
                }

                // view dropdown (every page): view modes + zoom slider
                QQC2.ToolButton {
                    id: viewBtn
                    icon.name: root.iconFor(root.viewOptions, root.currentViewMode, "view-list-icons")
                    onClicked: viewPopup.open()
                    QQC2.ToolTip.text: i18n("View & zoom"); QQC2.ToolTip.visible: hovered

                    QQC2.Popup {
                        id: viewPopup
                        y: viewBtn.height
                        x: viewBtn.width - width
                        padding: Kirigami.Units.smallSpacing
                        contentItem: ColumnLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Repeater {
                                model: root.viewOptions
                                delegate: QQC2.RadioButton {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    text: modelData.label
                                    icon.name: modelData.icon
                                    checked: root.currentViewMode === modelData.id
                                    onClicked: root.setViewMode(modelData.id)
                                }
                            }
                            QQC2.Button {
                                visible: root.gamesActive
                                Layout.fillWidth: true
                                text: i18n("Refresh games")
                                icon.name: "view-refresh"
                                onClicked: gamesView.reload()
                            }
                            Kirigami.Separator { Layout.fillWidth: true }
                            RowLayout {
                                Layout.fillWidth: true
                                QQC2.Label { text: i18n("Zoom"); opacity: 0.7 }
                                QQC2.Slider {
                                    id: zoomSlider
                                    Layout.fillWidth: true
                                    from: root.gamesActive ? 100 : 32
                                    to: root.gamesActive ? 320 : 160
                                    stepSize: root.gamesActive ? 10 : 8
                                    value: root.gamesActive ? Plasmoid.configuration.gameCardWidth
                                                            : Plasmoid.configuration.iconSize
                                    onMoved: {
                                        if (root.gamesActive) Plasmoid.configuration.gameCardWidth = value
                                        else Plasmoid.configuration.iconSize = value
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // ---- content ----
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // app category page: a pinned Favourites section on top (only for
                // "All Applications"), then the category grid/list below it
                ColumnLayout {
                    anchors.fill: parent
                    spacing: Kirigami.Units.smallSpacing
                    visible: !root.gamesActive && !root.favActive

                    // ---- pinned Favourites section (All Applications only) ----
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        visible: root.allAppsActive && favStrip.items.length > 0
                        horizontalAlignment: Text.AlignHCenter
                        text: i18n("Favourites")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                    }
                    FavGrid {
                        id: favStrip
                        Layout.fillWidth: true
                        // cap the strip to two rows; it scrolls if there are more
                        Layout.preferredHeight: Math.min(favStrip.gridContentHeight, favStrip.rowHeight * 2)
                        visible: root.allAppsActive && favStrip.items.length > 0
                        favorites: root.favorites
                        searchText: root.searchText
                        onLaunched: root.launchAndClose()
                        onRemoveFav: function(resource) { root.toggleFavorite(resource, false) }
                    }
                    Kirigami.Separator {
                        Layout.fillWidth: true
                        visible: root.allAppsActive && favStrip.items.length > 0
                    }

                    AppGrid {
                        id: appGrid
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        appModel: (root.gamesActive || root.favActive) ? null : root.appModelFor(root.currentCat)
                        favSet: root.favSet
                        excludeFavorites: root.allAppsActive
                        viewMode: root.appViewMode
                        searchText: root.searchText
                        sortMode: root.sortMode
                        usage: root.usage
                        onLaunchedKey: function(key) { root.recordLaunch(key); root.launchAndClose() }
                        onFavToggle: function(resource, add) { root.toggleFavorite(resource, add) }
                    }
                }

                FavGrid {
                    id: favGrid
                    anchors.fill: parent
                    visible: root.favActive
                    favorites: root.favorites
                    searchText: root.searchText
                    onLaunched: root.launchAndClose()
                    onRemoveFav: function(resource) { root.toggleFavorite(resource, false) }
                }

                GamesView {
                    id: gamesView
                    anchors.fill: parent
                    visible: root.gamesActive
                    active: root.gamesActive
                    cardWidth: Plasmoid.configuration.gameCardWidth
                    viewMode: Plasmoid.configuration.gamesViewMode
                    searchText: root.searchText
                    sortMode: root.sortMode
                    usage: root.usage
                    showTitles: Plasmoid.configuration.showGameTitles
                    portalBin: root.portalBin
                    onLaunched: root.launchAndClose()
                }

                // wheel interceptor on top: Ctrl+wheel zooms, plain wheel browses a
                // carousel, anything else falls through so grids/lists scroll. NoButton
                // lets clicks pass straight to the views beneath.
                MouseArea {
                    anchors.fill: parent
                    z: 50
                    acceptedButtons: Qt.NoButton
                    onWheel: function(wheel) {
                        if (wheel.modifiers & Qt.ControlModifier) {
                            root.zoom(wheel.angleDelta.y > 0 ? 1 : -1)
                            wheel.accepted = true
                        } else if (root.gamesActive && gamesView.isCarousel) {
                            gamesView.browse(wheel.angleDelta.y > 0 ? -1 : 1)
                            wheel.accepted = true
                        } else {
                            wheel.accepted = false
                        }
                    }
                }
            }
        }
    }
}
