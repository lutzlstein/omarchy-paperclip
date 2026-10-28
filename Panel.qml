pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.lutzlstein.paperclip"
  ipcTarget: "io.github.lutzlstein.paperclip"
  manageIpc: false

  readonly property string apiUrl: String(setting("apiUrl", "http://localhost:3100")).replace(/\/+$/, "")
  readonly property string serviceUnit: String(setting("serviceUnit", "paperclipai.service"))
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property string status: "checking"
  readonly property bool running: status === "running"

  // Set when the user flips the service; cleared once systemd reports the
  // requested state (or the timeout fires) so the switch shows progress.
  property string pendingStatus: ""
  readonly property bool busy: pendingStatus !== "" && pendingStatus !== status

  // ---- Network mode. Localhost-only is the default; the tailnet section
  // appears only when Tailscale is installed, logged in and running.
  // (Room for a future "setup" state, e.g. PaperclipAI not installed.)
  readonly property bool tailnetEnabled: true
  readonly property int tailnetHttpsPort: validPort(setting("tailnetHttpsPort", 443))
  readonly property int localPort: validPort(portFromUrl(apiUrl))
  readonly property bool tailnetConfigValid: tailnetHttpsPort > 0 && localPort > 0
  // "checking" | "missing" | "loggedOut" | "off" | "on" | "conflict" | "invalid" | "error"
  property string tailnetState: "checking"
  property string tailnetHost: ""
  property string tailnetDetail: ""
  property int tailnetGeneration: 0
  property string tailnetOutBuf: ""
  property bool tailnetOverflow: false
  readonly property int tailnetMaxBytes: 65536
  readonly property bool tailnetVisible: tailnetState === "on" || tailnetState === "off"
    || tailnetState === "conflict" || (tailnetBusy && tailnetHost !== "")
  readonly property bool tailnetBusy: tailnetToggleProc.running
  readonly property string tailnetUrl: tailnetHost === "" ? ""
    : "https://" + tailnetHost + (tailnetHttpsPort === 443 ? "" : ":" + tailnetHttpsPort)

  property var health: null
  property string healthError: ""

  // Keyboard cursor: one flat list of controls, top to bottom.
  //   0 = service switch, then one entry per action below.
  readonly property var actions: (tailnetVisible ? [
    { key: "tailnet", icon: "󰖂", label: tailnetActionLabel(), hotkey: "T" },
    { key: "copyurl", icon: "󰆏", label: "Copy tailnet URL", hotkey: "C" }
  ] : []).concat([
    { key: "logs", icon: "󰦪", label: "View logs", hotkey: "V" },
    { key: "web", icon: "󰖟", label: "Open web UI", hotkey: "O" },
    { key: "refresh", icon: "󰑐", label: "Refresh status", hotkey: "R" }
  ])
  readonly property int cursorCount: actions.length + 1
  property int cursorIndex: 0
  property bool cursorActive: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    cursorIndex = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onStatusChanged: {
    if (pendingStatus !== "" && status === pendingStatus) pendingStatus = ""
    if (running && opened) refreshTimer.restart()
    if (!running) health = null
  }

  function toggleService() {
    if (busy) return
    pendingStatus = running ? "stopped" : "running"
    pendingTimer.restart()
    Quickshell.execDetached(["systemctl", "--user", running ? "stop" : "start", serviceUnit])
  }

  function openLogs() {
    // bat's ansi theme maps log syntax onto the terminal palette, so colors
    // follow the Omarchy theme. Plain journalctl if bat is missing.
    var script = 'if command -v bat >/dev/null; then ' +
      'journalctl --user -f -n 200 -o cat -u "$1" | bat --paging=never --style=plain --color=always --theme=ansi -l log; ' +
      'else journalctl --user -f -n 200 -u "$1"; fi'
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=io.github.lutzlstein.paperclip.logs",
      "bash", "-c", script, "paperclip-logs", serviceUnit])
    close()
  }

  function openWeb() {
    Quickshell.execDetached(["xdg-open", apiUrl])
    close()
  }

  function validPort(value) {
    var n = Number(value)
    return (Number.isInteger(n) && n >= 1 && n <= 65535) ? n : 0
  }

  // Explicit port from apiUrl, else 3100 (PaperclipAI's default).
  function portFromUrl(url) {
    var m = /^[a-z]+:\/\/(?:\[[^\]]*\]|[^\/:?#]*)(?::(\d{1,5}))?/i.exec(String(url))
    return m && m[1] ? Number(m[1]) : 3100
  }

  function tailnetActionLabel() {
    if (tailnetBusy) return "Tailnet: working…"
    if (tailnetState === "on") return "Stop tailnet serve"
    if (tailnetState === "off") return "Serve on tailnet"
    if (tailnetState === "conflict") return "Tailnet port in use"
    if (tailnetState === "invalid") return "Tailnet: invalid port"
    return "Tailnet: " + tailnetState
  }

  function tailnetStateText() {
    switch (tailnetState) {
      case "on": return "serving"
      case "off": return "not serving"
      case "conflict": return "port " + tailnetHttpsPort + " used elsewhere"
      case "invalid": return "invalid port setting"
      case "error": return "error"
      default: return tailnetState
    }
  }

  function pollTailnet() {
    if (!tailnetEnabled) return
    if (!tailnetConfigValid) { tailnetState = "invalid"; return }
    if (tailnetToggleProc.running || tailnetProc.running) return
    tailnetGeneration += 1
    tailnetOutBuf = ""
    tailnetOverflow = false
    tailnetProc.stage = "status"
    tailnetProc.generation = tailnetGeneration
    tailnetProc.running = true
  }

  // Input: {"status": <tailscale status --json --peers=false>, "serve": <serve status --json>}
  function applyTailnet(statusObj, serveObj) {
    var backend = statusObj && typeof statusObj.BackendState === "string" ? statusObj.BackendState : ""
    var self = statusObj && statusObj.Self ? statusObj.Self : null
    var host = self && typeof self.DNSName === "string" ? self.DNSName.replace(/\.$/, "") : ""
    tailnetHost = /^[A-Za-z0-9.-]{1,253}$/.test(host) ? host : ""
    if (backend !== "Running") { tailnetState = "loggedOut"; tailnetDetail = backend; return }
    var web = serveObj && serveObj.Web && typeof serveObj.Web === "object" ? serveObj.Web : {}
    var tcp = serveObj && serveObj.TCP && typeof serveObj.TCP === "object" ? serveObj.TCP : {}
    var suffix = ":" + tailnetHttpsPort
    var entry = null
    for (var key in web) {
      if (key.length > suffix.length && key.slice(-suffix.length) === suffix) { entry = web[key]; break }
    }
    var tcpEntry = tcp[String(tailnetHttpsPort)]
    if (!entry) {
      // A raw TCP forward on this port is someone else's config.
      tailnetState = tcpEntry && tcpEntry.TCPForward ? "conflict" : "off"
      tailnetDetail = tcpEntry && tcpEntry.TCPForward ? String(tcpEntry.TCPForward).slice(0, 120) : ""
      return
    }
    var handlers = entry.Handlers || {}
    var rootH = handlers["/"]
    var proxy = rootH && typeof rootH.Proxy === "string" ? rootH.Proxy.replace(/\/+$/, "") : ""
    var ours = proxy === "http://127.0.0.1:" + localPort || proxy === "http://localhost:" + localPort
      || proxy === "127.0.0.1:" + localPort || proxy === "localhost:" + localPort
    var count = 0
    for (var h in handlers) count += 1
    if (ours && count === 1) { tailnetState = "on"; tailnetDetail = ""; return }
    tailnetState = "conflict"
    tailnetDetail = proxy !== "" ? proxy.slice(0, 120) : "other handlers"
  }

  function toggleTailnet() {
    if (!tailnetEnabled || tailnetBusy) return
    if (!tailnetConfigValid) { tailnetState = "invalid"; return }
    var https = "--https=" + tailnetHttpsPort
    var argv
    if (tailnetState === "on")
      argv = ["timeout", "15", "tailscale", "serve", https, "off"]
    else if (tailnetState === "off")
      argv = ["timeout", "15", "tailscale", "serve", "--bg", https, "http://127.0.0.1:" + localPort]
    else return   // never overwrite a conflicting mapping or act while logged out
    tailnetGeneration += 1   // drop any in-flight status read
    tailnetState = "checking"
    tailnetToggleProc.command = argv
    tailnetToggleProc.running = true
  }

  function copyTailnetUrl() {
    if (tailnetUrl === "") return
    Quickshell.execDetached(["wl-copy", "--", tailnetUrl])
  }

  function pollStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function refresh() {
    pollStatus()
    pollTailnet()
    if (healthProc.running) return
    healthProc.running = true
  }

  function runAction(key) {
    if (key === "tailnet") toggleTailnet()
    else if (key === "copyurl") copyTailnetUrl()
    else if (key === "logs") openLogs()
    else if (key === "web") openWeb()
    else if (key === "refresh") refresh()
  }

  function moveCursor(delta) {
    if (!cursorActive) { cursorActive = true; return }
    cursorIndex = Math.max(0, Math.min(cursorCount - 1, cursorIndex + delta))
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
  }

  function activateCursor() {
    if (!cursorActive) { cursorActive = true; return }
    if (cursorIndex === 0) toggleService()
    else runAction(actions[cursorIndex - 1].key)
  }

  function featureList() {
    var features = health && health.features
    if (!features || typeof features !== "object") return []
    var out = []
    for (var name in features) out.push({ name: name, enabled: features[name] === true })
    return out
  }

  function uptimeText() {
    var started = health && health.serverInfo ? Date.parse(health.serverInfo.processStartedAt) : NaN
    if (isNaN(started)) return "—"
    var mins = Math.max(0, Math.floor((Date.now() - started) / 60000))
    if (mins < 60) return mins + "m"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + "h " + (mins % 60) + "m"
    return Math.floor(hours / 24) + "d " + (hours % 24) + "h"
  }

  function backupText() {
    var backup = health ? health.databaseBackup : null
    if (!backup || !backup.enabled) return "disabled"
    if (backup.lastFailure) return "failed"
    if (!backup.latestBackup) return backup.status || "—"
    var age = Number(backup.latestBackup.ageHours)
    return (backup.status || "ok") + " · " + (age < 1 ? Math.round(age * 60) + "m ago" : age.toFixed(1) + "h ago")
  }

  onServiceUnitChanged: pollStatus()

  Timer {
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.pollStatus()
  }

  Process {
    id: statusProc
    command: ["systemctl", "--user", "is-active", root.serviceUnit]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = String(text || "").trim()
        root.status = state === "active" ? "running" : (state === "inactive" || state === "" ? "stopped" : state)
      }
    }
  }

  Timer {
    id: pendingTimer
    interval: 15000
    onTriggered: root.pendingStatus = ""
  }

  Timer {
    id: refreshTimer
    interval: 10000
    repeat: true
    running: root.opened && root.running
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  Process {
    id: healthProc
    command: ["curl", "-fsS", "--max-time", "3", root.apiUrl + "/api/health"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        try {
          root.health = raw ? JSON.parse(raw) : null
          root.healthError = raw ? "" : "No response from API"
        } catch (e) {
          root.health = null
          root.healthError = "Invalid response from API"
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.health = null
        root.healthError = root.running ? "API unreachable on :3100" : ""
      }
    }
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.opened && root.tailnetEnabled
    onTriggered: root.pollTailnet()
  }


  // Two bounded reads in sequence: tailscale status, then serve status.
  // Each has a 5 s `timeout`; stdout is capped while receiving.
  // `timeout` exits 127 when tailscale is not installed.
  Process {
    id: tailnetProc
    property int generation: 0
    property string stage: "status"
    property var statusDoc: null
    command: stage === "status"
      ? ["timeout", "5", "tailscale", "status", "--json", "--peers=false"]
      : ["timeout", "5", "tailscale", "serve", "status", "--json"]
    stdout: SplitParser {
      onRead: function(line) {
        if (root.tailnetOverflow) return
        if (root.tailnetOutBuf.length + line.length > root.tailnetMaxBytes) {
          root.tailnetOverflow = true
          root.tailnetOutBuf = ""
          tailnetProc.signal(15)
          return
        }
        root.tailnetOutBuf += line + "\n"
      }
    }
    onExited: function(exitCode) {
      var raw = root.tailnetOutBuf
      root.tailnetOutBuf = ""
      var overflow = root.tailnetOverflow
      root.tailnetOverflow = false
      var st = stage
      stage = "status"
      if (generation !== root.tailnetGeneration) return
      if (exitCode === 127) { root.tailnetState = "missing"; return }
      if (overflow) { root.tailnetState = "error"; root.tailnetDetail = "status output too large"; return }
      var doc = null
      try { doc = raw.trim().charAt(0) === "{" ? JSON.parse(raw) : null } catch (e) { doc = null }
      if (st === "status") {
        if (!doc) { root.tailnetState = "loggedOut"; root.tailnetDetail = ""; return }
        if (doc.BackendState !== "Running") { root.applyTailnet(doc, null); return }
        statusDoc = doc
        stage = "serve"
        Qt.callLater(function() { if (tailnetProc.generation === root.tailnetGeneration) tailnetProc.running = true })
        return
      }
      if (exitCode !== 0) { root.tailnetState = "error"; root.tailnetDetail = "tailscale serve status failed"; return }
      // Empty or non-JSON output means no serve config.
      root.applyTailnet(statusDoc, doc || {})
    }
  }

  Process {
    id: tailnetToggleProc
    stderr: StdioCollector { id: tailnetToggleErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.tailnetDetail = String(tailnetToggleErr.text || "tailscale serve failed").trim().slice(0, 160)
      root.pollTailnet()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleService(): void { root.toggleService() }
    function toggleTailnet(): void { root.toggleTailnet() }
    function tailnetStatus(): string { return root.tailnetState }
    function status(): string { return root.status }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰏢"
    foreground: root.running ? Color.accent : Color.muted
    tooltipText: root.opened ? "" : "PaperclipAI: " + root.status
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleService()
      else if (b === Qt.MiddleButton) root.openLogs()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "s") root.toggleService()
        else if (k === "v") root.openLogs()
        else if (k === "o") root.openWeb()
        else if (k === "r") root.refresh()
        else if (k === "t") root.toggleTailnet()
        else if (k === "c") root.copyTailnetUrl()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---- Hero: icon · title/status · service switch
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // PanelHero's trailingControl resolves `root` to the hero, so
            // panel state is reached through `header`.
            readonly property bool ringVisible: root.cursorActive && root.cursorIndex === 0
            function focusSwitch() { root.setCursor(0) }

            PanelHero {
              id: hero
              width: parent.width
              title: "PaperclipAI"
              meta: root.busy
                ? (root.pendingStatus === "running" ? "Starting…" : "Stopping…")
                : (root.running ? "Service running" : "Service " + root.status)
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.running ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: "󰏢"
                  color: root.running ? Color.accent : Color.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: root.busy ? root.pendingStatus === "running" : root.running
                  busy: root.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusSwitch() }
                  onToggled: root.toggleService()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: (root.running ? "Stop" : "Start") + " service (S)"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // ---- Live details from /api/health
          Column {
            visible: root.running
            width: parent.width
            spacing: Style.spacing.labelGap

            Text {
              visible: root.healthError !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: root.healthError
              color: Commons.Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            InfoPair { visible: root.health !== null; label: "Version"; value: root.health ? (root.health.version || "—") : "" }
            InfoPair { visible: root.health !== null; label: "Uptime"; value: root.uptimeText() }
            InfoPair { visible: root.health !== null; label: "Bootstrap"; value: root.health ? (root.health.bootstrapStatus || "—") : "" }
            InfoPair { visible: root.health !== null; label: "Auth"; value: root.health && root.health.authReady ? "ready" : "not ready" }
            InfoPair { visible: root.health !== null; label: "Backup"; value: root.backupText() }
          }

          Column {
            visible: root.running && root.featureList().length > 0
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "FEATURES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.featureList()
              InfoPair {
                required property var modelData
                label: modelData.name
                value: modelData.enabled ? "on" : "off"
              }
            }
          }

          Column {
            visible: root.tailnetVisible
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "TAILNET"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            InfoPair { label: "Serve"; value: root.tailnetBusy ? "working…" : root.tailnetStateText() }
            InfoPair { visible: root.tailnetUrl !== ""; label: "URL"; value: root.tailnetUrl }
            InfoPair { label: "Maps"; value: ":" + root.tailnetHttpsPort + " → 127.0.0.1:" + root.localPort }
            Text {
              visible: root.tailnetDetail !== "" && root.tailnetState !== "on" && root.tailnetState !== "off"
              width: parent.width
              textFormat: Text.PlainText
              text: root.tailnetState === "conflict"
                ? "Held by " + root.tailnetDetail + ". Left unchanged."
                : root.tailnetDetail
              color: Commons.Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---- Actions: keyboard cursor targets 1..n
          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.actions
              Button {
                required property var modelData
                required property int index
                width: parent.width
                leftAlign: true
                iconText: modelData.icon
                text: modelData.label + "   " + modelData.hotkey
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: modelData.key === "refresh"
                  || (modelData.key === "tailnet" ? (!root.tailnetBusy && (root.tailnetState === "on" || root.tailnetState === "off"))
                  : modelData.key === "copyurl" ? root.tailnetUrl !== ""
                  : root.running)
                hasCursor: root.cursorActive && root.cursorIndex === index + 1
                onHovered: function(h) { if (h) root.setCursor(index + 1) }
                onClicked: root.runAction(modelData.key)
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "↑↓ move · Enter select · S start/stop · Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)

    Text {
      id: pairLabel
      anchors.left: parent.left
      textFormat: Text.PlainText
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: pairValue
      anchors.right: parent.right
      anchors.left: pairLabel.right
      anchors.leftMargin: Style.space(8)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
