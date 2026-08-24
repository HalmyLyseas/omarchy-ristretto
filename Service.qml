import QtQuick

// P0 scaffold: loads, holds no state, does nothing. The suspend-after-idle-lock
// state machine lands here once the panel is reading and writing config.
Item {
  id: root

  // Injected by omarchy-shell's first-party service loader.
  property var shell: null
}
