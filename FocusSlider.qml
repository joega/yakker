import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// Retain the shell's pointer/drag behavior; share focus, spacing and key steps.
Item {
  id: root
  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 1
  property real pageStep: step * 5
  property bool integer: false
  property bool hasCursor: false
  property color foreground: bar ? bar.barForeground : Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color fillColor: accent
  property color knobColor: fillColor
  property string valueText: String(Math.round(displayValue))
  readonly property bool dragging: slider.dragging
  readonly property real liveValue: slider.liveValue
  readonly property real displayValue: dragging ? liveValue : value
  readonly property bool controlFocused: activeFocus || hasCursor
  readonly property bool controlHovered: slider._hot
  readonly property var controlSpec: controlFocused ? Border.controlSpec("focus", foreground, accent)
    : controlHovered ? Border.controlSpec("hover-cursor", foreground, accent) : Border.none()
  signal moved(real value)
  signal released(real value)
  signal rightClicked()
  signal pointerUsed()

  implicitWidth: Style.space(200)
  implicitHeight: Style.space(36)
  activeFocusOnTab: true
  Accessible.role: Accessible.Slider
  Accessible.description: valueText + ". Left and right adjust; Page Up and Page Down take larger steps; Home and End go to the limits."
  Accessible.onIncreaseAction: adjustBy(step)
  Accessible.onDecreaseAction: adjustBy(-step)

  function adjustTo(next) {
    if (!enabled || maximum <= minimum) return
    next = Math.max(minimum, Math.min(maximum, integer ? Math.round(next) : next))
    moved(next)
    released(next)
  }
  function adjustBy(amount) { adjustTo(value + amount) }
  function handleKey(event) {
    if (!enabled || event.modifiers !== Qt.NoModifier) return false
    if (event.key === Qt.Key_Left || event.text === "h") adjustBy(LayoutMirroring.enabled ? step : -step)
    else if (event.key === Qt.Key_Right || event.text === "l") adjustBy(LayoutMirroring.enabled ? -step : step)
    else if (event.key === Qt.Key_PageUp) adjustBy(pageStep)
    else if (event.key === Qt.Key_PageDown) adjustBy(-pageStep)
    else if (event.key === Qt.Key_Home) adjustTo(minimum)
    else if (event.key === Qt.Key_End) adjustTo(maximum)
    else return false
    event.accepted = true
    return true
  }
  Keys.onPressed: event => handleKey(event)

  Ui.BorderSurface {
    anchors.fill: parent
    radius: Style.space(8)
    color: Style.controlFill(root.controlFocused, root.controlHovered, root.foreground, root.accent)
    borderSpec: root.controlSpec
    opacity: root.enabled ? 1 : 0.4
  }
  QtObject {
    id: sliderPalette
    property color background: root.bar ? root.bar.background : Commons.Color.popups.background
  }
  Ui.PanelSlider {
    id: slider
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    bar: sliderPalette
    minimum: root.minimum
    maximum: root.maximum
    value: root.value
    step: root.step
    integer: root.integer
    knobSize: Style.space(16)
    trackHeight: Style.space(4)
    trackColor: Qt.alpha(root.foreground, root.controlFocused || root.controlHovered ? 0.24 : 0.15)
    fillColor: root.fillColor
    knobColor: root.controlFocused || root.controlHovered ? root.accent : root.knobColor
    opacity: root.enabled ? 1 : 0.4
    onDraggingChanged: if (dragging) root.forceActiveFocus(Qt.MouseFocusReason)
    onMoved: value => { root.pointerUsed(); root.moved(value) }
    onReleased: value => root.released(value)
    onRightClicked: { root.pointerUsed(); root.rightClicked() }
  }
}
