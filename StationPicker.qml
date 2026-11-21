import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

Item {
  id: root
  property string value: ""
  property var options: []
  property string triggerLabel: "Change station"
  property string placeholderText: "Station, city or country"
  property string emptyText: "No matching stations"
  property color foreground: Commons.Color.foreground
  property bool hasCursor: false
  property real popupWidth: width
  property real popupX: 0
  readonly property bool popupOpen: popup.opened
  readonly property var filtered: options.filter(function(option) {
    const query = search.text.trim().toLowerCase()
    return !query || (String(option.label) + " " + String(option.description || "")).toLowerCase().indexOf(query) >= 0
  })
  implicitHeight: Style.space(28)
  signal changed(string value)
  signal hovered(bool isHovered)
  function open() { popup.open() }
  function close() { popup.close() }
  function toggle() { popup.opened ? popup.close() : popup.open() }
  function selectCurrent() {
    if (list.currentIndex < 0 || list.currentIndex >= filtered.length) return
    root.changed(String(filtered[list.currentIndex].value))
    popup.close()
  }
  FocusButton {
    height: parent.height
    width: Math.min(parent.width, implicitWidth + Style.space(20))
    text: root.triggerLabel
    leftAlign: true
    fontSize: Style.fontPx(1)
    horizontalPadding: Style.space(2)
    verticalPadding: Style.space(3)
    foreground: Commons.Color.accent
    hasCursor: root.hasCursor
    tooltipText: "Choose station · Search by station, city or country"
    onHovered: isHovered => root.hovered(isHovered)
    onClicked: root.toggle()
    FocusIcon { name: "down"; foreground: Commons.Color.accent; width: Style.space(14); height: width; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
  }
  QQC.Popup {
    id: popup
    x: root.popupX
    y: root.height + Style.space(4)
    width: root.popupWidth
    padding: Style.space(10)
    implicitHeight: Math.min(Style.space(360), search.height + list.contentHeight + Style.space(42))
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutsideParent
    onOpened: { search.text = ""; list.currentIndex = 0; Qt.callLater(function() { search.forceActiveFocus() }) }
    onClosed: search.text = ""
    background: Ui.BorderSurface {
      color: Commons.Color.popups.background
      radius: Style.space(12)
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    }
    contentItem: Column {
      spacing: Style.space(8)
      Ui.TextField {
        id: search
        width: parent.width
        placeholderText: root.placeholderText
        Accessible.name: placeholderText
        font.family: "Adwaita Sans"
        font.pixelSize: Style.fontPx(1.167)
        foreground: root.foreground
        onTextChanged: list.currentIndex = 0
        Keys.onDownPressed: { if (list.count) list.forceActiveFocus() }
        Keys.onReturnPressed: root.selectCurrent()
        Keys.onEnterPressed: root.selectCurrent()
        Keys.onEscapePressed: root.close()
      }
      ListView {
        id: list
        width: parent.width
        height: Math.max(0, popup.availableHeight - search.height - parent.spacing)
        clip: true
        model: root.filtered
        spacing: Style.space(2)
        currentIndex: 0
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        Keys.onUpPressed: { if (currentIndex <= 0) search.forceActiveFocus(); else currentIndex-- }
        Keys.onDownPressed: currentIndex = Math.min(count - 1, currentIndex + 1)
        Keys.onReturnPressed: root.selectCurrent()
        Keys.onEnterPressed: root.selectCurrent()
        Keys.onEscapePressed: root.close()
        delegate: FocusButton {
          required property var modelData
          required property int index
          width: list.width
          height: labels.implicitHeight + Style.space(16)
          hasCursor: list.activeFocus && list.currentIndex === index
          foreground: root.foreground
          tooltipText: modelData.label + (modelData.description ? " · " + modelData.description : "")
          onClicked: { list.currentIndex = index; root.selectCurrent() }
          onHovered: isHovered => { if (isHovered) list.currentIndex = index }
          Column {
            id: labels
            anchors.verticalCenter: parent.verticalCenter
            x: Style.space(8)
            width: parent.width - Style.space(16)
            spacing: Style.space(3)
            Text { width: parent.width; text: modelData.label; textFormat: Text.PlainText; color: root.foreground; font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1.167); elide: Text.ElideRight }
            Text { width: parent.width; text: modelData.description || ""; textFormat: Text.PlainText; color: root.foreground; opacity: 0.75; font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1); elide: Text.ElideRight; visible: text.length > 0 }
          }
        }
        Text { visible: list.count === 0; width: parent.width; text: root.emptyText; textFormat: Text.PlainText; color: root.foreground; font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1.167); padding: Style.space(8) }
      }
    }
  }
}
