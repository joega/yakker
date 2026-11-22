import QtQuick
import QtQuick.Window
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
  property bool favoritesOnly: false
  property string highlightedValue: ""
  property var sessionOrder: []
  readonly property bool popupOpen: popup.opened
  readonly property int favoriteCount: options.filter(function(option) { return option.favorite === true }).length
  readonly property var filtered: {
    const terms = search.text.trim().toLowerCase().split(/\s+/).filter(function(term) { return !!term })
    const rows = options.filter(function(option) {
      const detail = [option.name, option.label, option.description, option.city, option.countryName, option.station ? option.station.country : ""].join(" ").toLowerCase()
      return (!root.favoritesOnly || option.favorite === true) && terms.every(function(term) { return detail.indexOf(term) >= 0 })
    })
    // Keep rows in place while hearts change. Reapply favorite-first order on
    // the next opening, so a click never moves a different station under it.
    if (root.popupOpen && root.sessionOrder.length) rows.sort(function(a,b) {
      const rank = function(option) { const index = root.sessionOrder.indexOf(String(option.value)); return index < 0 ? root.sessionOrder.length : index }
      return rank(a) - rank(b)
    })
    return rows
  }
  onFilteredChanged: if (popup.opened) Qt.callLater(restoreCurrent)
  implicitHeight: Style.space(28)
  signal changed(string value)
  signal favoriteRequested(string value)
  signal hovered(bool isHovered)
  function open() { popup.open() }
  function close() { popup.close() }
  function toggle() { popup.opened ? popup.close() : popup.open() }
  function nameFor(option) { return String(option.name || option.label || "Station") }
  function detailsFor(option) {
    if (!option.station) return String(option.description || "")
    const location = [option.city, option.countryName].filter(function(part) { return !!part }).join(" · ")
    return location + (option.station.custom ? (location ? " · " : "") + "Custom" : "")
  }
  function setCurrent(index) {
    list.currentIndex = filtered.length ? Math.max(0, Math.min(filtered.length - 1, index)) : -1
    highlightedValue = list.currentIndex >= 0 ? String(filtered[list.currentIndex].value) : ""
    if (list.currentIndex >= 0) list.positionViewAtIndex(list.currentIndex, ListView.Contain)
  }
  function restoreCurrent() {
    if (!popup.opened) return
    const index = filtered.findIndex(function(option) { return String(option.value) === root.highlightedValue })
    setCurrent(index >= 0 ? index : Math.max(0, list.currentIndex))
  }
  function selectCurrent() {
    if (list.currentIndex < 0 || list.currentIndex >= filtered.length) return
    root.changed(String(filtered[list.currentIndex].value))
    popup.close()
  }
  function toggleFavorite(value) {
    highlightedValue = value
    favoriteRequested(value)
    Qt.callLater(function() { if (popup.opened) {
      root.restoreCurrent()
      if (root.filtered.length) list.forceActiveFocus(); else search.forceActiveFocus()
    } })
  }
  FocusButton {
    height: parent.height
    width: Math.min(parent.width, implicitWidth + Style.space(20))
    text: root.triggerLabel
    leftAlign: true
    fontSize: Style.fontPx(1)
    horizontalPadding: Style.space(6)
    verticalPadding: Style.space(3)
    foreground: Commons.Color.accent
    hasCursor: root.hasCursor
    tooltipText: "Choose station · Search by station, city or country"
    onHovered: isHovered => root.hovered(isHovered)
    onClicked: root.toggle()
    FocusIcon { name: "down"; foreground: Commons.Color.accent; width: Style.space(14); height: width; anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter }
  }
  QQC.Popup {
    id: popup
    x: root.popupX
    y: root.height + Style.space(4)
    width: Math.min(root.popupWidth, root.Window.window ? Math.max(0, root.Window.window.width - Style.space(16)) : root.popupWidth)
    padding: Style.space(10)
    margins: Style.space(8)
    implicitHeight: Math.min(Style.space(420), pickerHeader.implicitHeight + (list.count ? list.contentHeight : pickerEmpty.implicitHeight) + pickerFooter.implicitHeight + Style.space(36))
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutsideParent
    onOpened: {
      root.sessionOrder = root.options.map(function(option) { return String(option.value) })
      root.favoritesOnly = false; search.text = ""
      root.highlightedValue = root.value
      Qt.callLater(function() { if (popup.opened) { root.restoreCurrent(); search.forceActiveFocus() } })
    }
    onClosed: { search.text = ""; root.sessionOrder = [] }
    background: Ui.BorderSurface {
      color: Commons.Color.popups.background
      radius: Style.space(12)
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    }
    contentItem: Column {
      spacing: Style.space(8)
      Column {
        id: pickerHeader
        width: parent.width
        spacing: Style.space(8)
        Text { width: parent.width; text: "Choose station"; textFormat: Text.PlainText; color: root.foreground; font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1.25); font.weight: Font.DemiBold }
        Row {
          width: parent.width
          spacing: Style.space(6)
          FocusTextField {
            id: search
            searchField: true
            width: parent.width - (clearSearch.visible ? clearSearch.width + parent.spacing : 0)
            placeholderText: root.placeholderText
            Accessible.name: placeholderText
            font.family: "Adwaita Sans"
            font.pixelSize: Style.fontPx(1.167)
            foreground: root.foreground
            onTextChanged: root.setCurrent(0)
            Keys.onDownPressed: { if (list.count) { root.setCurrent(Math.max(0, list.currentIndex)); list.forceActiveFocus() } }
            Keys.onReturnPressed: root.selectCurrent()
            Keys.onEnterPressed: root.selectCurrent()
            Keys.onEscapePressed: root.close()
          }
          FocusButton { id: clearSearch; visible: !!search.text; width: Style.space(28); height: Style.space(32); anchors.verticalCenter: parent.verticalCenter; iconName: "close"; iconSize: Style.space(14); tooltipText: "Clear search"; foreground: root.foreground; focusable: true; onClicked: { search.text = ""; search.forceActiveFocus() } }
        }
        Row {
          width: parent.width
          spacing: Style.space(6)
          FocusButton { id: allFilter; text: "All"; fontSize: Style.fontPx(1); foreground: root.foreground; selected: !root.favoritesOnly; focusable: true; onClicked: { root.favoritesOnly = false; root.setCurrent(0) } }
          FocusButton { id: favoritesFilter; text: "Favorites"; iconName: "heart"; iconSize: Style.space(14); fontSize: Style.fontPx(1); foreground: root.foreground; selected: root.favoritesOnly; focusable: true; onClicked: { root.favoritesOnly = true; root.setCurrent(0) } }
          Text { width: Math.max(0, parent.width - allFilter.width - favoritesFilter.width - parent.spacing * 2); anchors.verticalCenter: parent.verticalCenter; text: root.filtered.length + (root.filtered.length === 1 ? " station" : " stations"); horizontalAlignment: Text.AlignRight; textFormat: Text.PlainText; color: Qt.alpha(root.foreground, 0.65); font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1) }
        }
      }
      ListView {
        id: list
        visible: count > 0
        width: parent.width
        height: Math.max(0, popup.availableHeight - pickerHeader.height - pickerFooter.height - parent.spacing * 2)
        clip: true
        onHeightChanged: if (popup.opened) Qt.callLater(root.restoreCurrent)
        model: root.filtered
        spacing: Style.space(4)
        currentIndex: -1
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        Keys.onUpPressed: { if (currentIndex <= 0) search.forceActiveFocus(); else root.setCurrent(currentIndex - 1) }
        Keys.onDownPressed: root.setCurrent(currentIndex + 1)
        Keys.onReturnPressed: root.selectCurrent()
        Keys.onEnterPressed: root.selectCurrent()
        Keys.onEscapePressed: root.close()
        Keys.onPressed: event => {
          if (event.key === Qt.Key_F && event.modifiers === Qt.NoModifier && list.currentIndex >= 0) {
            root.toggleFavorite(String(root.filtered[list.currentIndex].value)); event.accepted = true
          }
        }
        delegate: Item {
          id: stationRow
          required property var modelData
          required property int index
          width: list.width
          height: Style.space(64)
          FocusButton {
            id: stationResult
            width: parent.width - favoriteButton.width - Style.space(6)
            height: parent.height
            selected: String(stationRow.modelData.value) === root.value
            hasCursor: list.activeFocus && list.currentIndex === stationRow.index
            foreground: root.foreground
            tooltipText: root.nameFor(stationRow.modelData) + (root.detailsFor(stationRow.modelData) ? " · " + root.detailsFor(stationRow.modelData) : "")
            onClicked: { root.setCurrent(stationRow.index); root.selectCurrent() }
            onHovered: isHovered => { if (isHovered) root.setCurrent(stationRow.index) }
            StationLogo { id: stationArtwork; x: Style.space(8); width: Style.space(34); height: width; anchors.verticalCenter: parent.verticalCenter; station: stationRow.modelData.station || ({}); fallbackColor: root.foreground }
            Column {
              anchors.verticalCenter: parent.verticalCenter
              x: Style.space(50)
              width: parent.width - x - Style.space(8)
              spacing: Style.space(4)
              Text { id: stationTitle; width: parent.width; text: root.nameFor(stationRow.modelData); textFormat: Text.PlainText; color: root.foreground; font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1.167); font.weight: stationResult.selected ? Font.DemiBold : Font.Medium; elide: Text.ElideRight }
              Text { width: parent.width; text: root.detailsFor(stationRow.modelData); textFormat: Text.PlainText; color: Qt.alpha(root.foreground, 0.7); font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(1); elide: Text.ElideRight; visible: !!text }
              Text { visible: stationResult.selected; text: "Selected station"; textFormat: Text.PlainText; color: Commons.Color.accent; font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(0.833) }
            }
          }
          FocusButton {
            id: favoriteButton
            width: Style.space(32)
            height: Style.space(36)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalPadding: 0
            iconName: stationRow.modelData.favorite ? "heart-filled" : "heart"
            iconSize: Style.space(18)
            foreground: stationRow.modelData.favorite ? Commons.Color.accent : Qt.alpha(root.foreground, 0.65)
            tooltipText: (stationRow.modelData.favorite ? "Remove favorite · " : "Add favorite · ") + root.nameFor(stationRow.modelData)
            Accessible.checkable: true
            Accessible.checked: stationRow.modelData.favorite === true
            focusable: true
            onActiveFocusChanged: if (activeFocus) root.setCurrent(stationRow.index)
            onClicked: root.toggleFavorite(String(stationRow.modelData.value))
          }
        }

      }
      Flickable {
        id: emptyViewport
        visible: list.count === 0
        width: parent.width
        height: Math.max(0, popup.availableHeight - pickerHeader.height - pickerFooter.height - parent.spacing * 2)
        contentHeight: pickerEmpty.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        StateCard {
          id: pickerEmpty
          width: parent.width
          title: root.favoritesOnly && !root.favoriteCount ? "No favorites yet" : !root.options.length ? "Stations unavailable" : "No matching stations"
          description: root.favoritesOnly && !root.favoriteCount ? "Save stations using the hearts in All stations."
            : !root.options.length ? "The station list hasn’t loaded. Close the picker and try again after reconnecting."
            : root.favoritesOnly ? "Try another search, or switch to All stations." : "Try a station name, city or country."
          iconName: "search"
          foreground: root.foreground
          actionText: !root.options.length ? "Close picker" : root.favoritesOnly && !root.favoriteCount ? "Show all stations" : search.text ? "Clear search" : "Show all stations"
          ensureVisible: function(item) {
            const y = item.mapToItem(pickerEmpty, 0, 0).y
            if (y < emptyViewport.contentY) emptyViewport.contentY = y
            else if (y + item.height > emptyViewport.contentY + emptyViewport.height) emptyViewport.contentY = Math.min(Math.max(0, emptyViewport.contentHeight - emptyViewport.height), y + item.height - emptyViewport.height)
          }
          onAction: {
            if (!root.options.length) { root.close(); return }
            if (!search.text || !root.favoriteCount) root.favoritesOnly = false
            search.text = ""; root.setCurrent(0)
            Qt.callLater(function() { if (popup.opened) search.forceActiveFocus() })
          }
        }
      }
      Text { id: pickerFooter; width: parent.width; text: "↑↓ Browse · Enter Select · F Favorite · Esc Close"; textFormat: Text.PlainText; color: Qt.alpha(root.foreground, 0.6); font.family: "Adwaita Sans"; font.pixelSize: Style.fontPx(0.833); wrapMode: Text.Wrap }
    }
  }
}
