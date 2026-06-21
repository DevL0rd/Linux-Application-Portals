import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    property alias cfg_icon: iconField.text
    property alias cfg_avatarSize: sizeSpin.value
    property alias cfg_showCountBadge: badge.checked

    // toolbar state lives in the popup; declared here so the config dialog
    // doesn't reset it on save
    property string cfg_sortMode
    property bool cfg_hideOffline
    property string cfg_favorites

    RowLayout {
        Kirigami.FormData.label: i18n("Panel icon:")
        QQC2.TextField { id: iconField; placeholderText: i18n("icon name") }
    }
    RowLayout {
        Kirigami.FormData.label: i18n("Avatar size:")
        QQC2.SpinBox { id: sizeSpin; from: 24; to: 96; stepSize: 4 }
        QQC2.Label { text: i18n("px"); opacity: 0.6 }
    }
    QQC2.CheckBox {
        id: badge
        Kirigami.FormData.label: i18n("Panel:")
        text: i18n("Online-count badge on the panel icon")
    }
}
