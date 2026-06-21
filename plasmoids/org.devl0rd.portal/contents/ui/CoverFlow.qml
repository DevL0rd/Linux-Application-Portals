/*
 * Hand-positioned cover flow. Each card's horizontal offset from the centre
 * follows a decaying curve: the centre card has a small gap to its neighbours,
 * and cards stack progressively tighter toward the edges (geometric falloff),
 * filling the width. `tilt` turns the side cards sideways (3D) when true.
 */
import QtQuick
import Qt5Compat.GraphicalEffects
import org.kde.kirigami as Kirigami

Item {
    id: cf
    clip: true
    property var items: []
    property var friendsByAppid: ({})   // appid -> friends list, for the badge
    function friendCountFor(g) {
        return (g && g.appid && friendsByAppid[g.appid]) ? friendsByAppid[g.appid].length : 0
    }
    property bool tilt: false             // turn side cards sideways (3D)
    property bool shrink: true            // scale side cards down toward the edges
    property int cardWidth: 150           // requested (zoom) width; acts as a maximum
    property bool showTitles: true
    signal launchRequested(var game)
    signal menuRequested(var game)

    // cards are sized to FIT the available height (card + reflection + padding), so
    // they're never cut off; the zoom width is just the upper bound. Resizing the
    // widget rescales the whole strip.
    readonly property real _pad: Kirigami.Units.largeSpacing
    readonly property real _maxFitH: Math.max(80, (height - _pad * 2) / 1.1)        // biggest card that fits
    readonly property real _minH: Math.min(_maxFitH, Kirigami.Units.gridUnit * 6)
    // map the whole zoom slider (100..320) onto small..max-fit, so the top of the
    // slider is always the largest card that fits and zoom never plateaus
    readonly property real _zoomFrac: Math.max(0, Math.min(1, (cardWidth - 100) / 220))
    readonly property real cardH: _minH + (_maxFitH - _minH) * _zoomFrac
    readonly property real cw: cardH / 1.5
    readonly property real reflH: cardH * 0.4       // reflection fades to nothing by here (via the mask, no clip)

    // leaving the whole strip clears the armed Play button
    HoverHandler { id: cfHover; onHoveredChanged: if (!hovered) cf.centerArmed = false }

    property real pos: 0                  // centre position (fractional item index)
    property int targetIndex: 0
    property bool centerArmed: false      // does the centred card show its Play button?
    readonly property real unitSpacing: Math.max(20, cw * 0.6)  // px per index while dragging

    // infinite loop: shortest signed distance from the centre, wrapped over the list
    function wrapD(raw) {
        var n = items ? items.length : 0
        if (n <= 1) return raw
        return raw - n * Math.round(raw / n)
    }

    NumberAnimation { id: posAnim; target: cf; property: "pos"; easing.type: Easing.OutCubic }
    function glideTo(i) {
        targetIndex = Math.round(i)        // unbounded -> wraps via wrapD in delegates
        posAnim.stop()
        posAnim.from = pos
        posAnim.to = targetIndex
        posAnim.duration = Math.max(150, Math.min(750, 150 + Math.abs(targetIndex - pos) * 110))
        posAnim.start()
    }
    function browse(step) { centerArmed = false; glideTo(targetIndex + step) }   // wheel (glides)
    onItemsChanged: posAnim.stop()

    // drag with momentum (PathView used to give this for free; we do it by hand)
    DragHandler {
        id: dragH
        target: null
        xAxis.enabled: true
        yAxis.enabled: false
        property real startPos: 0
        onActiveChanged: {
            if (active) { posAnim.stop(); startPos = cf.pos; cf.centerArmed = false }
            else cf.glideTo(cf.pos - (centroid.velocity.x / cf.unitSpacing) * 0.32)  // fling
        }
        onTranslationChanged: if (active) cf.pos = startPos - translation.x / cf.unitSpacing
    }

    // centre card has a clear gap to its neighbour (no heavy overlap), and the fan
    // converges to the widget edge so cards stack tighter and tighter outward
    readonly property real baseGap: cw * (tilt ? 0.9 : 1.05)   // carousel tighter, shelf wider
    // flat cards stay full-width, so converge them inside the edge; 3D cards
    // foreshorten, so they can reach (slightly past) the edge
    readonly property real maxOffset: Math.max(baseGap * 1.5,
        width / 2 + (tilt ? cw * 0.1 : -cw * 0.35))
    // cap the falloff so cards converge to the edge within a sensible count (a too-
    // gentle falloff makes zoomed-out cards never reach the edge)
    readonly property real falloff: Math.max(0.5, Math.min(0.85, 1 - baseGap / maxOffset))
    function offsetFor(d) {
        var off = maxOffset * (1 - Math.pow(falloff, Math.abs(d)))
        return d < 0 ? -off : off
    }

    Repeater {
        model: cf.items
        delegate: Item {
            id: tile
            readonly property real d: cf.wrapD(index - cf.pos)   // looped distance from centre
            readonly property real ad: Math.abs(d)
            readonly property real off: cf.offsetFor(d)
            readonly property real cardH: cf.cardH
            readonly property real reflH: cf.reflH
            width: cf.cw
            height: cardH                       // tile is just the card; reflection hangs below
            visible: Math.abs(off) < cf.width / 2 + cf.cw
            x: cf.width / 2 + off - width / 2
            // centre the CARD vertically (equal padding above/below it); the
            // reflection renders full below and the outer carousel clips whatever
            // runs past the bottom edge
            y: (cf.height - cardH) / 2
            z: Math.round(2000 - ad * 10)
            scale: cf.shrink ? Math.max(0.5, 0.55 + 0.45 * Math.pow(0.82, ad)) : 1.0
            // fade only as a card nears the widget edge (not by index), so cards fill
            // the width and don't vanish early when zoomed out
            opacity: {
                var dist = Math.abs(off)
                var fs = cf.width / 2 - cf.cw * 0.6
                return dist < fs ? 1.0 : Math.max(0.0, 1.0 - (dist - fs) / (cf.cw * 1.2))
            }
            transform: Rotation {
                origin.x: tile.width / 2; origin.y: tile.height / 2
                axis { x: 0; y: 1; z: 0 }
                // gentle near the centre, ramping up toward the edges (not full early)
                angle: cf.tilt ? (d < 0 ? 1 : -1) * 72 * (1 - Math.pow(0.6, ad)) : 0
            }

            // soft drop shadow behind the card
            Rectangle {
                x: 0; y: Kirigami.Units.smallSpacing
                width: tile.width; height: tile.cardH
                radius: Kirigami.Units.smallSpacing
                color: "#000000"; opacity: 0.35
                z: -1
            }

            GameCard {
                id: cfCard
                anchors.fill: parent
                game: modelData
                friendCount: cf.friendCountFor(modelData)
                showTitle: cf.showTitles
                disarmOnExit: false                        // CoverFlow manages arming
                armed: tile.ad < 0.5 && cf.centerArmed     // only the centred card, when armed
                // one click: glide this card to centre the shortest (looped) way AND
                // arm it (show Play)
                onCardClicked: { cf.glideTo(cf.pos + tile.d); cf.centerArmed = true }
                onLaunchRequested: cf.launchRequested(modelData)
                onMenuRequested: cf.menuRequested(modelData)
            }

            // floor reflection: flipped lower strip of the card, fading downward
            // The area is short (reflH) and CLIPS a normal, full-length reflection.
            // The reflection (reflFull) renders at full card height with a natural
            // fade over its whole length; the area just shows the top of it.
            // Reflection: a full 1:1 mirror that the GRADIENT MASK itself fades to
            // nothing. No clip:true anywhere -- wrapping this masked layer in a
            // clipping container was killing the fade (hard edge). The mask's
            // transparency is what "cuts" the reflection, cleanly.
            Item {
                id: reflWrap
                anchors.top: cfCard.bottom
                anchors.horizontalCenter: cfCard.horizontalCenter
                width: cfCard.width
                height: cfCard.height
                opacity: 0.32
                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: LinearGradient {
                        width: reflWrap.width; height: reflWrap.height
                        start: Qt.point(0, 0); end: Qt.point(0, reflWrap.height)
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#c0ffffff" }
                            GradientStop { position: tile.reflH / tile.cardH; color: "#00ffffff" }
                            GradientStop { position: 1.0; color: "#00ffffff" }
                        }
                    }
                }
                ShaderEffectSource {
                    anchors.fill: parent
                    sourceItem: cfCard
                    live: true
                    transform: Scale { origin.y: reflWrap.height / 2; yScale: -1 }
                }
            }
        }
    }
}
