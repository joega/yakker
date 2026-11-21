import QtQuick
import QtQuick.Window
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

FocusScope {
  id: root
  property string label: ""
  property string value: ""
  property var options: []
  property bool searchable: false
  property bool showLabel: true
  property string placeholderText: "Choose an option"
  property string emptyText: "No matching options"
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: "Adwaita Sans"
  property int rowHeight: Style.space(36)
  property int popupRowHeight: Style.space(40)
  property bool hasCursor: false
  readonly property bool popupOpen: popup.opened
  readonly property var filtered: {
    const terms = search.text.trim().toLowerCase().split(/\s+/).filter(function(term) { return !!term })
    return options.filter(function(option) {
      const text = (root.optionLabel(option) + " " + root.optionDescription(option)).toLowerCase()
      return terms.every(function(term) { return text.indexOf(term) >= 0 })
    })
  }
  signal changed(string value)
  signal hovered(bool isHovered)
  function optionValue(option) { return option && typeof option === "object" ? String(option.value) : String(option) }
  function optionLabel(option) { return option && typeof option === "object" ? String(option.label || option.name || "") : String(option) }
  function optionDescription(option) { return option && typeof option === "object" ? String(option.description || "") : "" }
  function currentLabel() {
    const option = options.find(function(option) { return root.optionValue(option) === root.value })
    return option === undefined ? value : optionLabel(option)
  }
  function open() { if (enabled) popup.open() }
  function close() { popup.close() }
  function toggle() { popup.opened ? close() : open() }
  function chooseCurrent() {
    if (results.currentIndex < 0 || results.currentIndex >= filtered.length) return
    const nextValue = optionValue(filtered[results.currentIndex])
    changed(nextValue)
    close()
  }
  function moveCurrent(direction) {
    if (!results.count) return
    results.currentIndex = Math.max(0, Math.min(results.count - 1, results.currentIndex + direction))
    results.positionViewAtIndex(results.currentIndex, ListView.Contain)
  }
  implicitWidth: Style.spacing.dropdownWidth
  implicitHeight: fieldColumn.implicitHeight
  Column {
    id: fieldColumn
    width: parent.width
    spacing: Style.space(6)
    Text {
      visible: root.showLabel && !!root.label
      text: root.label
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.fontPx(1.083)
      font.weight: Font.DemiBold
    }
    FocusTextField {
      id: trigger
      width: parent.width
      height: Math.max(root.rowHeight, implicitHeight)
      focus: true
      font.family: root.fontFamily
      text: ""
      placeholderText: ""
      foreground: root.foreground
      accent: root.accent
      readOnly: true
      cursorVisible: false
      controlActive: root.popupOpen
      hasCursor: root.hasCursor || triggerHover.hovered
      rightPadding: horizontalPadding + reservedRight + Style.space(22)
      Accessible.role: Accessible.ComboBox
      Accessible.name: root.label || root.placeholderText
      Accessible.description: root.currentLabel()
      HoverHandler { id: triggerHover; onHoveredChanged: root.hovered(hovered) }
      Text {
        id: triggerLabel
        anchors.left: parent.left; anchors.right: dropdownChevron.left
        anchors.leftMargin: trigger.leftPadding; anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: root.currentLabel() || root.placeholderText
        textFormat: Text.PlainText
        color: root.currentLabel() ? root.foreground : Qt.alpha(root.foreground,0.6)
        font.family: root.fontFamily
        font.pixelSize: trigger.font.pixelSize
        elide: Text.ElideRight
      }
      FocusIcon { id: dropdownChevron; name: "down"; foreground: root.foreground; width: Style.space(16); height: width; anchors.right: parent.right; anchors.rightMargin: trigger.horizontalPadding + trigger.reservedRight; anchors.verticalCenter: parent.verticalCenter }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { trigger.forceActiveFocus(); root.toggle() } }
      Keys.onPressed: event => {
        if ([Qt.Key_Return,Qt.Key_Enter,Qt.Key_Space,Qt.Key_Down].indexOf(event.key) >= 0) { event.accepted = true; root.toggle() }
        else if (event.key === Qt.Key_Escape && root.popupOpen) { event.accepted = true; root.close() }
      }
    }
  }
  QQC.Popup {
    id: popup
    y: root.height + Style.space(4)
    width: Math.min(root.width, root.Window.window ? root.Window.window.width - Style.space(16) : root.width)
    implicitHeight: Math.min(Style.space(360), (root.searchable ? search.implicitHeight + Style.space(8) : 0) + Math.max(Style.space(40), results.contentHeight) + padding * 2)
    margins: Style.space(8)
    padding: Style.space(8)
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutsideParent
    onOpened: {
      search.text = ""
      const selected = root.filtered.findIndex(function(option) { return root.optionValue(option) === root.value })
      results.currentIndex = Math.max(0, selected)
      Qt.callLater(function() {
        if (!popup.opened) return
        if (root.searchable) search.forceActiveFocus()
        else { results.forceActiveFocus(); if (results.count) results.positionViewAtIndex(results.currentIndex, ListView.Contain) }
      })
    }
    onClosed: { search.text = ""; if (root.visible && root.enabled) trigger.forceActiveFocus() }
    background: Ui.BorderSurface { color: Commons.Color.popups.background; borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth); radius: Style.space(8) }
    contentItem: Column {
      spacing: Style.space(8)
      FocusTextField {
        id: search
        visible: root.searchable
        width: parent.width
        searchField: true
        clearable: true
        placeholderText: "Search stations"
        Accessible.name: placeholderText
        font.family: root.fontFamily
        foreground: root.foreground
        accent: root.accent
        onTextChanged: results.currentIndex = root.filtered.length ? 0 : -1
        Keys.onDownPressed: { if (results.count) { results.currentIndex = Math.max(0,results.currentIndex); results.forceActiveFocus() } }
        Keys.onReturnPressed: event => { event.accepted = true; root.chooseCurrent() }
        Keys.onEnterPressed: event => { event.accepted = true; root.chooseCurrent() }
        Keys.onEscapePressed: event => { event.accepted = true; root.close() }
      }
      Item {
        width: parent.width
        height: Math.max(0, popup.availableHeight - (search.visible ? search.height + parent.spacing : 0))
        Text { anchors.fill: parent; visible: results.count === 0; text: root.emptyText; textFormat: Text.PlainText; color: Qt.alpha(root.foreground,0.7); font.family: root.fontFamily; font.pixelSize: Style.fontPx(1.167); horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; wrapMode: Text.Wrap }
        ListView {
          id: results
          anchors.fill: parent
          clip: true
          model: root.filtered
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          activeFocusOnTab: true
          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
          keyNavigationEnabled: false
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: event => {
            if (event.key === Qt.Key_Down || event.text === "j") { event.accepted = true; root.moveCurrent(1) }
            else if (event.key === Qt.Key_Up || event.text === "k") {
              event.accepted = true
              if (root.searchable && currentIndex <= 0) search.forceActiveFocus()
              else root.moveCurrent(-1)
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { event.accepted = true; root.chooseCurrent() }
            else if (event.key === Qt.Key_Escape) { event.accepted = true; root.close() }
          }
          delegate: FocusButton {
            required property var modelData
            required property int index
            width: results.width
            height: root.optionDescription(modelData) ? Style.space(50) : root.popupRowHeight
            foreground: root.foreground
            accent: root.accent
            selected: root.value === root.optionValue(modelData)
            hasCursor: results.activeFocus && results.currentIndex === index
            leftAlign: true
            focusable: true
            activeFocusOnTab: false
            Accessible.role: Accessible.ListItem
            Accessible.name: root.optionLabel(modelData) + " " + root.optionDescription(modelData)
            onHovered: isHovered => { if (isHovered) results.currentIndex = index }
            onClicked: { results.currentIndex = index; root.chooseCurrent() }
            Column {
              anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(2)
              Text { width: parent.width; text: root.optionLabel(modelData); textFormat: Text.PlainText; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.fontPx(1.167); font.bold: parent.parent.selected; elide: Text.ElideRight }
              Text { width: parent.width; visible: !!text; text: root.optionDescription(modelData); textFormat: Text.PlainText; color: Qt.alpha(root.foreground,0.7); font.family: root.fontFamily; font.pixelSize: Style.fontPx(1); elide: Text.ElideRight }
            }
          }
        }
      }
    }
  }
}
