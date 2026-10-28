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
  readonly property string serviceUnitSetting: String(setting("serviceUnit", "paperclipai.service"))
  // Unit names are passed as argv; reject anything option-shaped or odd.
  readonly property string serviceUnit: /^[A-Za-z0-9][A-Za-z0-9@._:-]{0,254}$/.test(serviceUnitSetting)
    ? serviceUnitSetting : "paperclipai.service"
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

  // ---- Setup. When neither the unit nor a `paperclipai` CLI exists the
  // panel shows a setup view. The plugin never installs anything itself:
  // Node is only suggested (Omarchy's own installer), and PaperclipAI's
  // official onboarding runs in a visible terminal after a user action.
  // "checking" | "installed" | "needsNode" | "ready" | "error"
  property string setupState: "checking"
  property string nodeVersion: ""
  property string setupDetail: ""
  property string probeBuf: ""
  property bool probeOverflow: false
  property int probeGeneration: 0
  readonly property bool setupMode: setupState === "needsNode" || setupState === "ready"
  // Source: /usr/share/omarchy/bin/omarchy-install-dev-env (node → `mise use --global node`).
  readonly property string nodeInstallCommand: "omarchy install dev-env node"
  // Source: paperclipai README Quickstart + `paperclipai onboard --help`.
  // Loopback (localhost-only) is the quickstart default; --install-service
  // registers the paperclipai.service systemd user unit.
  readonly property string setupCommand: "npx paperclipai@latest onboard --yes --install-service"
  readonly property int nodeMinMajor: 24
  readonly property int nodeMinMinor: 11

  // ---- Provider CLI login state (non-secret status commands only).
  // "" = CLI not found (row hidden) | "checking" | "in" | "out" | "error"
  property string claudeState: ""
  property string codexState: ""
  property string claudeBuf: ""
  property bool claudeOverflow: false
  property double adaptersPolledAt: 0
  readonly property bool adaptersVisible: claudeState !== "" || codexState !== ""

  property var health: null
  property string healthError: ""

  // Keyboard cursor: one flat list of controls, top to bottom.
  //   0 = service switch, then one entry per action below.
  readonly property var actions: setupState === "needsNode" ? [
    { key: "copynode", icon: "󰆏", label: "Copy Node install command", hotkey: "C" },
    { key: "refresh", icon: "󰑐", label: "Check again", hotkey: "R" }
  ] : setupState === "ready" ? [
    { key: "setup", icon: "󰏗", label: "Set up PaperclipAI", hotkey: "U" },
    { key: "copysetup", icon: "󰆏", label: "Copy setup command", hotkey: "C" },
    { key: "refresh", icon: "󰑐", label: "Check again", hotkey: "R" }
  ] : (tailnetVisible ? [
    { key: "tailnet", icon: "󰖂", label: tailnetActionLabel(), hotkey: "T" },
    { key: "copyurl", icon: "󰆏", label: "Copy tailnet URL", hotkey: "C" }
  ] : []).concat([
    { key: "logs", icon: "󰦪", label: "View logs", hotkey: "V" },
    { key: "web", icon: "󰖟", label: "Open web UI", hotkey: "O" },
    { key: "refresh", icon: "󰑐", label: "Refresh status", hotkey: "R" }
  ])
  // In setup mode there is no service switch, so actions start at 0.
  readonly property int actionBase: setupMode ? 0 : 1
  readonly property int cursorCount: actions.length + actionBase
  property int cursorIndex: 0
  property bool cursorActive: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    cursorIndex = 0
    refresh(true)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onStatusChanged: {
    if (pendingStatus !== "" && status === pendingStatus) pendingStatus = ""
    if (running && opened) refreshTimer.restart()
    if (!running) health = null
  }

  function toggleService() {
    if (busy || setupMode || setupState === "checking") return
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

  function probeSetup() {
    if (probeProc.running) return
    probeGeneration += 1
    probeBuf = ""
    probeOverflow = false
    probeProc.generation = probeGeneration
    probeProc.running = true
  }

  // Lines from probeProc: unit=0|1, cli=0|1, node=<version or empty>, npx=0|1
  function applyProbe(raw) {
    var kv = {}
    var lines = raw.split("\n")
    for (var i = 0; i < lines.length && i < 16; i++) {
      var m = /^(unit|cli|node|npx)=(.{0,32})$/.exec(lines[i])
      if (m) kv[m[1]] = m[2]
    }
    if (kv.unit === undefined) { setupState = "error"; setupDetail = "Could not query systemd"; return }
    if (kv.unit === "1" || kv.cli === "1") { setupState = "installed"; setupDetail = ""; return }
    var v = /^v?(\d+)\.(\d+)\./.exec(kv.node || "")
    nodeVersion = v ? (v[1] + "." + v[2]) : ""
    var major = v ? Number(v[1]) : 0, minor = v ? Number(v[2]) : 0
    var nodeOk = v && (major > nodeMinMajor || (major === nodeMinMajor && minor >= nodeMinMinor))
    if (!nodeOk || kv.npx !== "1") {
      setupState = "needsNode"
      setupDetail = !v ? "Node.js was not found."
        : !nodeOk ? "Node.js " + nodeVersion + " found; PaperclipAI needs " + nodeMinMajor + "." + nodeMinMinor + " or newer."
        : "npx was not found."
      return
    }
    setupState = "ready"
    setupDetail = "Node.js " + nodeVersion + " found."
  }

  // Opens a visible terminal. The user reads the command and confirms with
  // "y" before it runs; nothing runs hidden. Fixed script, no interpolation.
  function runSetup() {
    if (setupState !== "ready") return
    var script = 'printf "PaperclipAI setup (localhost-only by default)\\n\\nThis will run:\\n  %s\\n\\n" "$1"; ' +
      'read -r -p "Continue? [y/N] " ans; ' +
      'if [[ $ans == [yY]* ]]; then npx paperclipai@latest onboard --yes --install-service; ' +
      'echo; echo "Setup finished (exit $?)."; else echo "Cancelled."; fi; ' +
      'read -r -p "Press Enter to close. " _'
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=io.github.lutzlstein.paperclip.setup",
      "bash", "-c", script, "paperclip-setup", setupCommand])
    close()
  }

  function copyText(t) {
    if (t !== "") Quickshell.execDetached(["wl-copy", "--", t])
  }

  function pollAdapters(force) {
    var now = Date.now()
    if (!force && now - adaptersPolledAt < 60000) return
    adaptersPolledAt = now
    if (!claudeProc.running) {
      claudeBuf = ""
      claudeOverflow = false
      claudeProc.running = true
    }
    if (!codexProc.running) codexProc.running = true
  }

  function adapterText(state) {
    switch (state) {
      case "in": return "logged in"
      case "out": return "signed out"
      case "checking": return "checking…"
      default: return "status unavailable"
    }
  }

  function refresh(force) {
    probeSetup()
    pollAdapters(force === true)
    if (setupMode) return
    pollStatus()
    pollTailnet()
    if (healthProc.running) return
    healthProc.running = true
  }

  function runAction(key) {
    if (key === "setup") runSetup()
    else if (key === "copysetup") copyText(setupCommand)
    else if (key === "copynode") copyText(nodeInstallCommand)
    else if (key === "tailnet") toggleTailnet()
    else if (key === "copyurl") copyTailnetUrl()
    else if (key === "logs") openLogs()
    else if (key === "web") openWeb()
    else if (key === "refresh") refresh(true)
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
    if (!setupMode && cursorIndex === 0) toggleService()
    else if (actions[cursorIndex - actionBase]) runAction(actions[cursorIndex - actionBase].key)
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

  // Bounded probe: fixed script, unit name as $1, 64 lines max, 10 s cap.
  // Includes mise shims so a Node installed by `omarchy install dev-env
  // node` is found even if the shell was started before it existed.
  Process {
    id: probeProc
    property int generation: 0
    command: ["timeout", "10", "bash", "-c",
      'if systemctl --user cat -- "$1" >/dev/null 2>&1; then echo unit=1; else echo unit=0; fi; ' +
      'command -v paperclipai >/dev/null 2>&1 && echo cli=1 || echo cli=0; ' +
      'PATH="$PATH:$HOME/.local/share/mise/shims"; ' +
      'if command -v node >/dev/null 2>&1; then echo "node=$(timeout 3 node --version 2>/dev/null | head -c 32)"; else echo node=; fi; ' +
      'command -v npx >/dev/null 2>&1 && echo npx=1 || echo npx=0',
      "paperclip-probe", root.serviceUnit]
    stdout: SplitParser {
      onRead: function(line) {
        if (root.probeOverflow) return
        if (root.probeBuf.length + line.length > 1024) { root.probeOverflow = true; return }
        root.probeBuf += line + "\n"
      }
    }
    onExited: function(exitCode) {
      if (generation !== root.probeGeneration) return
      if (root.probeOverflow) { root.setupState = "error"; root.setupDetail = "Probe output too large"; return }
      root.applyProbe(root.probeBuf)
    }
  }

  Timer {
    // Re-detect while the setup view is open (e.g. after the setup
    // terminal finishes). Only runs while the panel is open.
    interval: 5000
    repeat: true
    running: root.opened && root.setupMode
    onTriggered: root.probeSetup()
  }

  onSetupStateChanged: if (setupState === "installed" && opened) { pollStatus(); refresh(false) }

  // `timeout` exits 127 when the CLI is not on PATH → row hidden.
  // Only `loggedIn` is read from claude's JSON; nothing else is kept.
  Process {
    id: claudeProc
    command: ["timeout", "8", "claude", "auth", "status", "--json"]
    stdout: SplitParser {
      onRead: function(line) {
        if (root.claudeOverflow) return
        if (root.claudeBuf.length + line.length > 16384) { root.claudeOverflow = true; root.claudeBuf = ""; return }
        root.claudeBuf += line + "\n"
      }
    }
    onExited: function(exitCode) {
      var raw = root.claudeBuf
      root.claudeBuf = ""
      if (exitCode === 127) { root.claudeState = ""; return }
      if (root.claudeOverflow || exitCode === 124) { root.claudeState = "error"; return }
      var loggedIn = null
      try { var d = JSON.parse(raw); loggedIn = d && typeof d.loggedIn === "boolean" ? d.loggedIn : null } catch (e) { loggedIn = null }
      root.claudeState = loggedIn === true ? "in" : loggedIn === false ? "out" : "error"
    }
  }

  // Exit status only; output is not read.
  Process {
    id: codexProc
    command: ["timeout", "8", "codex", "login", "status"]
    onExited: function(exitCode) {
      root.codexState = exitCode === 127 ? "" : exitCode === 0 ? "in" : exitCode === 1 ? "out" : "error"
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
    function status(): string { return root.setupMode ? "setup" : root.status }
    function setupStatus(): string { return root.setupState }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰏢"
    foreground: root.running ? Color.accent : Color.muted
    tooltipText: root.opened ? "" : "PaperclipAI: " + (root.setupMode ? "not set up" : root.status)
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.openLogs()
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
        if (root.setupMode) {
          if (k === "u") root.runSetup()
          else if (k === "c") root.copyText(root.setupState === "ready" ? root.setupCommand : root.nodeInstallCommand)
          else if (k === "r") root.refresh(true)
          return
        }
        if (k === "s") root.toggleService()
        else if (k === "v") root.openLogs()
        else if (k === "o") root.openWeb()
        else if (k === "r") root.refresh(true)
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
            readonly property bool ringVisible: !root.setupMode && root.cursorActive && root.cursorIndex === 0
            function focusSwitch() { root.setCursor(0) }

            PanelHero {
              id: hero
              width: parent.width
              title: "PaperclipAI"
              meta: root.setupMode ? "Not set up yet" : root.busy
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
                  visible: !root.setupMode
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

          // ---- Setup view (replaces the switch when PaperclipAI is absent)
          Column {
            visible: root.setupMode || root.setupState === "error"
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "SETUP"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: root.setupState === "needsNode"
                ? root.setupDetail + " Install Node.js the Omarchy way in a terminal, then check again:"
                : root.setupState === "ready"
                ? "PaperclipAI is not installed (no " + root.serviceUnit + "). " + root.setupDetail
                  + " Set up opens a terminal, asks you to confirm, then runs PaperclipAI's official onboarding as a localhost-only user service:"
                : root.setupDetail
            }
            Text {
              visible: root.setupMode
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WrapAnywhere
              color: Color.accent
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
              text: root.setupState === "needsNode" ? root.nodeInstallCommand : root.setupCommand
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

            InfoPair { visible: root.health !== null && !!root.health.version; label: "Version"; value: root.health ? (root.health.version || "—") : "" }
            InfoPair { visible: root.health !== null && !!(root.health.serverInfo && root.health.serverInfo.processStartedAt); label: "Uptime"; value: root.uptimeText() }
            InfoPair { visible: root.health !== null; label: "Bootstrap"; value: root.health ? (root.health.bootstrapStatus || "—") : "" }
            InfoPair { visible: root.health !== null && typeof root.health.deploymentMode === "string"; label: "Mode"; value: root.health ? String(root.health.deploymentMode || "") + (root.health.deploymentExposure ? " · " + root.health.deploymentExposure : "") : "" }
            InfoPair { visible: root.health !== null && typeof root.health.authReady === "boolean"; label: "Auth"; value: root.health && root.health.authReady ? "ready" : "not ready" }
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
            visible: !root.setupMode && root.adaptersVisible
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "ADAPTER LOGINS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            InfoPair { visible: root.claudeState !== ""; label: "Claude"; value: root.adapterText(root.claudeState) }
            InfoPair { visible: root.codexState !== ""; label: "Codex"; value: root.adapterText(root.codexState) }
          }

          Column {
            visible: !root.setupMode && root.tailnetVisible
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
                enabled: modelData.key === "refresh" || modelData.key === "setup"
                  || modelData.key === "copysetup" || modelData.key === "copynode"
                  || (modelData.key === "tailnet" ? (!root.tailnetBusy && (root.tailnetState === "on" || root.tailnetState === "off"))
                  : modelData.key === "copyurl" ? root.tailnetUrl !== ""
                  : root.running)
                hasCursor: root.cursorActive && root.cursorIndex === index + root.actionBase
                onHovered: function(h) { if (h) root.setCursor(index + root.actionBase) }
                onClicked: root.runAction(modelData.key)
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.setupMode ? "↑↓ move · Enter select · Esc close" : "↑↓ move · Enter select · S start/stop · Esc close"
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
