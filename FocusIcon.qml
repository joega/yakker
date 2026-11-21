import QtQuick

// Small local vectors keep transport symbols sharp at every desktop scale.
Image {
  id: root
  property string name: ""
  property color foreground: "black"
  readonly property color opaqueForeground: Qt.rgba(foreground.r, foreground.g, foreground.b, 1)
  opacity: foreground.a
  readonly property var paths: ({
    "play": '<path d="M8 5l11 7-11 7z" fill="currentColor" stroke="none"/>',
    "pause": '<path d="M8 5v14M16 5v14" stroke-width="4"/>',
    "back": '<path d="M3 10a9 9 0 1 1 2 8M3 4v6h6"/>',
    "forward": '<g transform="translate(24 0) scale(-1 1)"><path d="M3 10a9 9 0 1 1 2 8M3 4v6h6"/></g>',
    "stop": '<rect x="6" y="6" width="12" height="12" rx="1" fill="currentColor" stroke="none"/>',
    "record": '<circle cx="12" cy="12" r="8"/>',
    "moon": '<path d="M20 15A9 9 0 0 1 9 4a9 9 0 1 0 11 11z"/>',
    "settings": '<path d="M5 4v4m0 4v8M12 4v9m0 4v3M19 4v2m0 4v10M2 8h6m1 9h6m1-11h6"/>',
    "heart": '<path d="M20 5a5 5 0 0 0-8 1 5 5 0 0 0-8-1c-3 3-1 6 8 14 9-8 11-11 8-14z"/>',
    "volume": '<path d="M11 4L6 8H3v8h3l5 4zM15 8a6 6 0 0 1 0 8M18 5a10 10 0 0 1 0 14"/>',
    "muted": '<path d="M11 4L6 8H3v8h3l5 4zM16 9l6 6m0-6l-6 6"/>',
    "down": '<path d="M6 9l6 6 6-6"/>',
    "left": '<path d="M14 6l-6 6 6 6"/>',
    "right": '<path d="M9 6l6 6-6 6"/>',
    "folder": '<path d="M3 6h6l2 2h10v12H3zM3 8V4h6l2 2h10v2"/>',
    "plus": '<path d="M12 5v14M5 12h14"/>',
    "radio": '<rect x="3" y="8" width="18" height="12" rx="3"/><path d="M5 8l13-5M15 12h3m-3 4h3"/><circle cx="8" cy="14" r="2"/>',
    "close": '<path d="M6 6l12 12M18 6L6 18"/>'
  })
  source: name && paths[name] ? "data:image/svg+xml;charset=utf-8," + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" color="' + opaqueForeground
      + '" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' + paths[name] + '</svg>') : ""
  sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
  fillMode: Image.PreserveAspectFit
  smooth: true
}
