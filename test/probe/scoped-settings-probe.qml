import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property string pluginDir: Quickshell.env("RISTRETTO_PLUGIN_DIR")
  property var checks: []
  property bool done: false
  property var service: null
  property var widget: null
  property var shellApi: null
  property var waiting: null
  property var continuation: null
  property int attempts: 0
  property var secondWidget: null
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
        var next = ({id: id})
        for (var key in settings) if (key !== "id") next[key] = settings[key]
        root.entry = next
        saveEntry(root.entry)
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
  FileView { id: configWriter; path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"; preload: false; atomicWrites: true }
  Process { id: removeConfig; command: ["/usr/bin/rm", Quickshell.env("HOME") + "/.config/omarchy/shell.json"] }
  function saveEntry(value) {
    configWriter.setText(JSON.stringify({version:1,bar:{layout:{right:value ? [value] : []}}}))
  }
  function until(predicate, next) { waiting = predicate; continuation = next; attempts = 0 }
  Timer {
    interval: 25; repeat: true; running: root.waiting !== null
    onTriggered: {
      if (!root.waiting()) {
        if (++root.attempts > 120) { check("settings propagation timeout", false); finish() }
        return
      }
      var next = root.continuation
      root.waiting = null
      root.continuation = null
      next()
    }
  }
  function exercise() {
    if (!widget || !widget._debugPanelItem) { check("real panel loaded", false); finish(); return }
    var p = widget._debugPanelItem
    check("scoped host", service.scopedHost === true)
    check("initial sleep", service.sleepSeconds === 60 && p.sleepSeconds === 60)
    check("initial sibling", p.dryRun === true)
    var generation = service._suspendGeneration
    p.commitSleep(300)
    check("write intent cancels before persistence", service._suspendGeneration > generation)
    check("entry merged", root.entry.sleepAfterIdleLock === 300 && root.entry.dryRun === true && root.entry.sibling === "kept")
    until(function() { return service.sleepSeconds === 300 }, function() {
      check("service follows persisted settings", p.sleepSeconds === 300 && service.dryRun === true)
      check("facade snapshot remains stale", shellApi.barConfig.layout.right[0].sleepAfterIdleLock === 60)
      saveEntry({id:"halmylyseas.ristretto",sleepAfterIdleLock:180,dryRun:false,sibling:"newer",newField:"preserved"})
      until(function() { return service.sleepSeconds === 180 && !service.dryRun }, function() {
        check("panel displays active external settings", p.sleepSeconds === 180 && !p.dryRun && root.entry.sleepAfterIdleLock === 300)
        p.commitSleep(240)
        check("fresh settings survive next widget edit",
              root.entry.sleepAfterIdleLock === 240 && root.entry.dryRun === false
              && root.entry.sibling === "newer" && root.entry.newField === "preserved")
        var component = Qt.createComponent("file://" + root.pluginDir + "/BarWidget.qml")
        secondWidget = component.createObject(root, {bar:barStub,settings:{sleepAfterIdleLock:600,dryRun:true}})
        check("stale second monitor cannot override settings", service.sleepSeconds === 180 && !service.dryRun)
        root.shellApi._serviceLookup = function(id) { return null }
        var old = service
        service = null
        old.destroy()
        Qt.callLater(function() {
          check("panel unavailable after destroy", p.suspendAvailable === false && p.heroStatus.indexOf("unavailable") >= 0)
          makeService()
          until(function() { return service.sleepSeconds === 240 }, function() {
            check("panel follows recreated service", p.ristrettoService === service && p.sleepSeconds === 240 && !p.dryRun)
            configWriter.setText("invalid JSON")
            until(function() { return service.sleepSeconds === -1 }, function() {
              check("invalid file clears stale settings", !service.dryRun && !!service.settingsDiagnostic && p.sleepSeconds === -1)
              p.commitSleep(600)
              check("invalid current entry rejects widget write", root.entry.sleepAfterIdleLock === 240)
              saveEntry(null)
              until(function() { return service.settingsDiagnostic === "missing own entry" }, function() {
                check("missing entry fails safe", service.sleepSeconds === -1)
                saveEntry({id:"halmylyseas.ristretto",sleepAfterIdleLock:240,dryRun:true})
                until(function() { return service.sleepSeconds === 240 }, function() {
                  removeConfig.running = true
                  until(function() { return service.sleepSeconds === -1 }, function() {
                    check("deleted file clears settings", !service.dryRun && !!service.settingsDiagnostic)
                    saveEntry({id:"halmylyseas.ristretto",sleepAfterIdleLock:120,dryRun:false})
                    until(function() { return service.sleepSeconds === 120 }, function() {
                      check("recreated file restores settings", p.sleepSeconds === 120 && !p.dryRun)
                      secondWidget.destroy()
                      finish()
                    })
                  })
                })
              })
            })
          })
        })
      })
    })
  }
  Component.onCompleted: initApi()
  Timer { id: settle; interval: 500; onTriggered: root.exercise() }
  Timer { interval: 12000; running: true; onTriggered: { check("probe timeout", false); finish() } }
}
