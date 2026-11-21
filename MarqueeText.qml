import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

Item {
  id: root
  property alias text: label.text
  property alias color: label.color
  property alias font: label.font
  property alias textFormat: label.textFormat
  property bool scrolling: true
  property bool initialized: false
  readonly property real overflowDistance: Math.max(0, label.implicitWidth - width)
  readonly property bool overflowing: overflowDistance > 1
  readonly property bool motionAllowed: initialized && scrolling && visible && overflowing && !Style.reduceMotion
  readonly property real offset: label.x
  readonly property bool truncated: label.truncated
  readonly property int travelDuration: Math.max(1200, Math.round(overflowDistance / Style.space(28) * 1000))
  implicitWidth: label.implicitWidth
  implicitHeight: label.implicitHeight
  height: implicitHeight
  clip: true
  Accessible.role: Accessible.StaticText
  Accessible.name: text

  function resetScroll() {
    if (!initialized) return
    motion.stop()
    label.x = 0
    if (motionAllowed) motion.start()
  }
  onTextChanged: resetScroll()
  onWidthChanged: resetScroll()
  onMotionAllowedChanged: resetScroll()
  onOverflowDistanceChanged: resetScroll()
  Component.onCompleted: { initialized = true; resetScroll() }

  Text {
    id: label
    width: root.motionAllowed ? implicitWidth : root.width
    textFormat: Text.PlainText
    wrapMode: Text.NoWrap
    maximumLineCount: 1
    elide: root.motionAllowed ? Text.ElideNone : Text.ElideRight
    Accessible.ignored: true
  }
  SequentialAnimation {
    id: motion
    loops: Animation.Infinite
    PauseAnimation { duration: Style.duration(1200) }
    NumberAnimation { target: label; property: "x"; from: 0; to: -root.overflowDistance; duration: Style.duration(root.travelDuration); easing.type: Easing.Linear }
    PauseAnimation { duration: Style.duration(1200) }
    NumberAnimation { target: label; property: "x"; from: -root.overflowDistance; to: 0; duration: Style.duration(root.travelDuration); easing.type: Easing.Linear }
  }
  HoverHandler { id: hover }
  QQC.ToolTip {
    visible: hover.hovered && root.overflowing
    delay: 400
    text: root.text
    padding: Style.space(8)
    background: Ui.BorderSurface {
      color: Commons.Color.tooltip.background
      radius: Style.cornerRadius
      borderSpec: Border.surfaceSpec("tooltip", "border", Commons.Color.tooltip.border, Style.normalBorderWidth)
    }
    contentItem: Text { text: root.text; textFormat: Text.PlainText; color: Commons.Color.tooltip.text; font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1) }
  }
}
