import QtQuick
import qs.Commons
import qs.Commons as Commons

// Shared guidance for empty lists and recoverable playback errors.
Rectangle {
  id: root
  property string title: ""
  property string description: ""
  property string iconName: ""
  property color foreground: Commons.Color.foreground
  property color iconColor: Commons.Color.accent
  property string actionText: ""
  property string secondaryText: ""
  property bool actionEnabled: true
  property bool secondaryEnabled: true
  property string detailText: ""
  property bool detailsExpanded: false
  property bool primaryCursor: false
  property bool secondaryCursor: false
  property bool detailsCursor: false
  property var ensureVisible: function(item) {}
  property alias primaryControl: primaryButton
  property alias secondaryControl: secondaryButton
  property alias detailsControl: detailsButton
  signal action()
  signal secondary()
  signal controlHovered(int index)
  implicitHeight: body.implicitHeight + Style.space(28)
  radius: Style.space(8)
  color: Qt.alpha(foreground, 0.035)
  onVisibleChanged: if (!visible) detailsExpanded = false
  onDetailTextChanged: detailsExpanded = false
  Column {
    id: body
    x: Style.space(14); y: Style.space(14)
    width: parent.width - Style.space(28)
    spacing: Style.space(10)
    Row {
      width: parent.width
      spacing: Style.space(10)
      FocusIcon { visible: !!root.iconName; width: visible ? Style.space(22) : 0; height: width; name: root.iconName; foreground: root.iconColor; anchors.verticalCenter: parent.verticalCenter }
      Text { width: parent.width - (root.iconName ? Style.space(32) : 0); text: root.title; textFormat: Text.PlainText; color: root.foreground; font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1.25); font.weight: Font.DemiBold; wrapMode: Text.Wrap }
    }
    Text { width: parent.width; visible: !!text; text: root.description; textFormat: Text.PlainText; color: Qt.alpha(root.foreground, 0.75); font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1.083); wrapMode: Text.Wrap }
    Flow {
      width: parent.width
      visible: !!root.actionText || !!root.secondaryText
      spacing: Style.space(6)
      FocusButton {
        id: primaryButton
        visible: !!root.actionText
        text: root.actionText
        fontSize: Style.fontPx(1)
        foreground: root.foreground
        color: Qt.alpha(Commons.Color.accent, 0.12)
        focusable: true
        hasCursor: root.primaryCursor
        enabled: root.actionEnabled
        opacity: enabled ? 1 : 0.4
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
        onHovered: isHovered => { if (isHovered) root.controlHovered(0) }
        onClicked: root.action()
      }
      FocusButton {
        id: secondaryButton
        visible: !!root.secondaryText
        text: root.secondaryText
        fontSize: Style.fontPx(1)
        foreground: Qt.alpha(root.foreground, 0.8)
        focusable: true
        hasCursor: root.secondaryCursor
        enabled: root.secondaryEnabled
        opacity: enabled ? 1 : 0.4
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
        onHovered: isHovered => { if (isHovered) root.controlHovered(1) }
        onClicked: root.secondary()
      }
    }
    FocusButton {
      id: detailsButton
      visible: !!root.detailText
      text: root.detailsExpanded ? "Hide details" : "Show details"
      fontSize: Style.fontPx(1)
      horizontalPadding: Style.space(6)
      foreground: Qt.alpha(root.foreground, 0.7)
      focusable: true
      hasCursor: root.detailsCursor
      Accessible.checkable: true
      Accessible.checked: root.detailsExpanded
      onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
      onHovered: isHovered => { if (isHovered) root.controlHovered(2) }
      onClicked: { root.detailsExpanded = !root.detailsExpanded; forceActiveFocus(); root.ensureVisible(this) }
    }
    Text { id: diagnostics; width: parent.width; visible: root.detailsExpanded && !!root.detailText; text: root.detailText; textFormat: Text.PlainText; color: Qt.alpha(root.foreground, 0.7); font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
  }
}
