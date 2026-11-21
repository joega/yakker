import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// Keep the native kit's focus, tooltip, keyboard, press and motion behavior.
Ui.Button {
  id: root
  property string iconName: ""
  fontFamily: "Adwaita Sans"
  fontSize: Style.fontPx(1.167)
  iconSize: Style.space(18)
  verticalPadding: Style.space(7)
  radius: Style.space(8)
  Accessible.role: Accessible.Button
  Accessible.name: tooltipText || text
  // An em space reserves the shared button's icon slot; the vector paints it.
  iconText: iconName ? "\u2003" : ""
  FocusIcon {
    visible: root.iconName !== ""
    name: root.iconName
    foreground: root.selected ? Style.selectedStateColor(root.foreground, root.accent) : root.foreground
    width: root.iconSize
    height: width
    x: root.leftAlign ? root._reservedContentLeftInset : (root.width - root._contentNaturalWidth) / 2
    anchors.verticalCenter: parent.verticalCenter
  }
}
