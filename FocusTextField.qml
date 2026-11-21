import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

Ui.TextField {
  id: root
  property bool searchField: false
  property bool clearable: false
  property bool controlActive: false
  readonly property bool fieldFocused: activeFocus || controlActive
  readonly property bool fieldHovered: hovered || hasCursor
  readonly property var normalSpec: Border.controlSpec("normal", foreground, accent)
  readonly property var hoverSpec: Border.controlSpec("hover-cursor", foreground, accent)
  readonly property var focusSpec: Border.controlSpec("focus", foreground, accent)
  readonly property var fieldSpec: fieldFocused ? focusSpec : fieldHovered ? hoverSpec : normalSpec
  readonly property real reservedLeft: Math.max(Border.left(normalSpec), Border.left(hoverSpec), Border.left(focusSpec))
  readonly property real reservedRight: Math.max(Border.right(normalSpec), Border.right(hoverSpec), Border.right(focusSpec))
  readonly property real reservedTop: Math.max(Border.top(normalSpec), Border.top(hoverSpec), Border.top(focusSpec))
  readonly property real reservedBottom: Math.max(Border.bottom(normalSpec), Border.bottom(hoverSpec), Border.bottom(focusSpec))
  font.family: "Adwaita Sans"
  font.pixelSize: Style.fontPx(1.167)
  horizontalPadding: Style.space(10)
  verticalPadding: Style.space(7)
  implicitHeight: Math.max(Style.space(36), Math.ceil(contentHeight) + topPadding + bottomPadding)
  clip: true
  hoverEnabled: true
  activeFocusOnTab: true
  selectByMouse: true
  placeholderTextColor: Qt.alpha(foreground, 0.6)
  // Reserve the largest border in every state, including hover/focus.
  leftPadding: horizontalPadding + reservedLeft + (searchField ? Style.space(22) : 0)
  rightPadding: horizontalPadding + reservedRight + (clearButton.visible ? clearButton.width + Style.space(4) : 0)
  topPadding: verticalPadding + reservedTop
  bottomPadding: verticalPadding + reservedBottom
  background: Ui.BorderSurface {
    color: Style.controlFill(root.fieldFocused, root.fieldHovered, root.foreground, root.accent)
    borderSpec: root.fieldSpec
    radius: Style.space(8)
  }
  FocusIcon {
    visible: root.searchField
    name: "search"
    width: Style.space(16); height: width
    x: root.horizontalPadding + root.reservedLeft
    anchors.verticalCenter: parent.verticalCenter
    foreground: Qt.alpha(root.foreground, 0.65)
  }
  FocusButton {
    id: clearButton
    visible: root.clearable && root.text.length > 0
    width: Style.space(26); height: Style.space(26)
    anchors.right: parent.right
    anchors.rightMargin: root.reservedRight + Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
    horizontalPadding: 0
    iconName: "close"
    iconSize: Style.space(14)
    foreground: root.foreground
    tooltipText: "Clear search"
    focusable: true
    onClicked: { root.clear(); root.forceActiveFocus() }
  }
}
