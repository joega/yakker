import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// Headless counterpart of the installed layer-shell wrapper. Retains its native
// card, border, padding and sizing; only the desktop anchoring is replaced.
Item {
  id: root
  property var anchorItem
  property var owner
  property var bar
  property bool open: false
  property var focusTarget
  property int contentWidth: 380
  property int contentHeight: 500
  default property alias contentItem: contentHolder.children
  width: contentWidth
  height: contentHeight
  function fittedContentWidth(value) { return value }
  function fittedContentHeight(value) { return Math.ceil(value + card.contentTopInset + card.contentBottomInset) }
  Ui.BorderSurface {
    id: card
    anchors.fill: parent
    color: Commons.Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
    padding: Style.spacing.popupPadding
    radius: Style.cornerRadius
    Item {
      id: contentHolder
      x: card.contentLeftInset
      y: card.contentTopInset
      width: root.width - card.contentLeftInset - card.contentRightInset
      height: root.height - card.contentTopInset - card.contentBottomInset
    }
  }
}
