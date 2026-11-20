import QtQuick
import qs.Commons

Item {
  id: root
  property var station: ({})
  property color fallbackColor: Color.foreground
  readonly property string artwork: station.artwork || ""

  Rectangle {
    anchors.fill: parent
    visible: !!root.station.artworkBackground && logo.status === Image.Ready
    color: root.station.artworkBackground || "transparent"
    radius: Style.space(3)
  }
  Image {
    id: logo
    anchors.fill: parent
    anchors.margins: root.station.artworkBackground ? Style.space(2) : 0
    source: root.artwork ? Qt.resolvedUrl(root.artwork) : ""
    sourceSize.width: 192
    sourceSize.height: 192
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    asynchronous: true
  }

  Text {
    anchors.centerIn: parent
    visible: !root.artwork || logo.status === Image.Error
    text: root.station.icon || "󰐹"
    textFormat: Text.PlainText
    color: root.fallbackColor
    font.family: Style.font.family
    font.pixelSize: Math.min(root.width, root.height)
  }
}
