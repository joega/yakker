import QtQuick
Item {
  property var anchorItem
  property var owner
  property var bar
  property bool open: false
  property var focusTarget
  property int contentWidth: 380
  property int contentHeight: 650
  width: contentWidth
  height: Math.min(contentHeight, owner ? owner.height : contentHeight)
  function fittedContentWidth(value) { return value }
  function fittedContentHeight(value) { return value }
}
