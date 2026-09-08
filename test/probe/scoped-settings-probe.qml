import QtQuick
import Quickshell

ShellRoot {
  id: root
  property string pluginDir: Quickshell.env("RISTRETTO_PLUGIN_DIR")
  property var checks: []
  property bool done: false
  property var service: null
  property var widget: null
  property var shellApi: null
  property var entry: ({id: "halmylyseas.ristretto", sleepAfterIdleLock: 60, dryRun: true, sibling: "kept"})

  function check(name, value) { checks = checks.concat([{name: name, pass: !!value}]) }
  function finish() {
    if (done) return
    done = true
    var failed = 0
    for (var i = 0; i < checks.length; i++) if (!checks[i].pass) failed++
    print("SCOPED_SETTINGS_RESULT " + JSON.stringify({failed: failed, checks: checks}))
    Qt.quit()
  }
  function initApi() {
      var component = Qt.createComponent("/usr/share/omarchy/shell/services/PluginShellApi.qml")
      var item = component.createObject(root, {pluginId: "halmylyseas.ristretto"})
      root.shellApi = item
      item.barConfig = ({layout: {left: [], center: [], right: [root.entry]}})
      item._serviceLookup = function(id) { return id === "halmylyseas.ristretto" ? root.service : null }
      item._firstPartyServiceLookup = function(id) { return null }
      item._updateSettings = function(id, settings) {
        if (id !== "halmylyseas.ristretto") return false
        root.entry = ({id: id, sleepAfterIdleLock: settings.sleepAfterIdleLock,
                       dryRun: settings.dryRun, sibling: settings.sibling})
        item.barConfig = ({layout: {left: [], center: [], right: [root.entry]}})
        if (root.widget) root.widget.settings = root.entry
        return true
      }
      root.makeService()
  }
  QtObject {
    id: barStub
    property color foreground: "#e6e6e6"
    property color background: "#101315"
    property color urgent: "#ff5555"
    property color barForeground: "#e6e6e6"
    property string fontFamily: "monospace"
    property string position: "top"
    property bool vertical: false
    property int barSize: 26
    property bool foregroundAnimationEnabled: true
    property var shell: root.shellApi
    property var activePopout: null
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) { if (activePopout === owner) activePopout = null }
    function moduleWidgets(name) { return [] }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
  }
  Loader {
    id: widgetLoader
    source: "file://" + root.pluginDir + "/BarWidget.qml"
    onLoaded: {
      root.widget = item
      item.bar = barStub
      item.settings = root.entry
      settle.start()
    }
  }
  function makeService() {
    var component = Qt.createComponent("file://" + root.pluginDir + "/Service.qml")
    var s = component.createObject(root)
    s.shell = root.shellApi
    s.minSleepSeconds = 1
    root.shellApi._serviceLookup = function(id) { return id === "halmylyseas.ristretto" ? root.service : null }
    service = s
    return s
  }
  function exercise() {
    if (!widget || !widget._debugPanelItem) {
      check("real panel loaded", false)
      finish()
      return
    }
    var p = widget._debugPanelItem
    check("scoped host", service.scopedHost === true)
    check("initial sleep", service.sleepSeconds === 60 && p.sleepSeconds === 60)
    check("initial sibling", p.dryRun === true)
    p.commitSleep(300)
    check("entry merged", root.entry.sleepAfterIdleLock === 300 && root.entry.dryRun === true && root.entry.sibling === "kept")
    check("service follows barConfig", service.sleepSeconds === 300)
    root.shellApi._serviceLookup = function(id) { return null }
    var old = service
    service = null
    old.destroy()
    Qt.callLater(function() {
      check("panel unavailable after destroy", p.suspendAvailable === false && p.heroStatus.indexOf("unavailable") >= 0)
      makeService()
      Qt.callLater(function() {
        check("panel follows recreated service", p.ristrettoService === service && p.ristrettoService !== old
          && !p.idleAvailable && p.suspendAvailable === false && service.sleepSeconds === 300
          && service.dryRun === true)
        finish()
      })
    })
  }
  Component.onCompleted: initApi()
  Timer { id: settle; interval: 500; onTriggered: root.exercise() }
  Timer { interval: 12000; running: true; onTriggered: { check("probe timeout", false); finish() } }
}
