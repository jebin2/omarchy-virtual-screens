import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Virtual Screens: extra screens (SCREEN-2..4) shown on other devices with
// Sunshine + Moonlight. All the work is done by bin/virtual-screen; this panel
// shows its `info-all` JSON and calls its commands.
Panel {
  id: root
  moduleName: "jebin2.virtual-screens"
  ipcTarget: "jebin2.virtual-screens"
  // A plugin's bar slot is sized by its button (built-ins get this from the bar).
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string binDir: decodeURIComponent(String(Qt.resolvedUrl("bin")).replace(/^file:\/\//, ""))
  readonly property string vsCmd: binDir + "/virtual-screen"
  // After setup the root helper runs from a root-owned copy (see virtual-screen-root).
  readonly property string rootHelperInstalled: "/usr/local/libexec/omarchy-virtual-screens-root"

  readonly property var vsNumbers: [2, 3, 4]       // fixed, so rows aren't rebuilt on refresh
  // Nothing is shown until the first info-all arrives (loaded: true).
  property var info: ({ loaded: false, screens: [], ready: false, wifi: null })
  // n -> {kind: "power"|"audio", target, wasOn, started}: an action in flight.
  // The row stays locked until info-all shows it done (or it times out).
  property var vsPending: ({})
  property int vsExpanded: -1                       // n of the row opened with the arrow
  property int vsPairFormFor: -1                    // n with "Pair a different device" open
  property int vsPairingFor: -1                     // n while a pair command runs
  property string vsPairPin: ""                     // sent on stdin, never in arguments
  property var vsHidden: ({})                       // n -> true: details closed with the arrow
  property int vsForgetFor: -1                      // n while a forget command runs
  property int vsMsgFor: -1
  property string vsMsg: ""
  property bool vsMsgOk: false
  property string rootMsg: ""          // last system-change failure, shown with a Report button
  property string rootLog: ""          // its output, for the report
  property string rootAction: ""       // "setup" | "wifi" while running
  property string rootFailedAction: ""
  property bool rootRunning: false
  property string rootNote: ""         // a hint from a successful setup
  property bool confirmUninstall: false
  property bool uninstalling: false

  property bool cursorActive: false
  property int selectedIndex: 0

  readonly property int onCount: {
    var c = 0
    for (var i = 0; i < vsNumbers.length; i++) if (vsData(vsNumbers[i]).on) c++
    return c
  }

  function vsData(n) {
    var list = root.info.screens || []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].n === n) return list[i]
    return { n: n, on: false, addresses: [], devices: [], audio: "laptop" }
  }
  function vsTitle(n) {
    return n === 2 ? strings.t("screen.second") : n === 3 ? strings.t("screen.third") : strings.t("screen.fourth")
  }
  function vsPendingOf(n) { return root.vsPending[n] || null }
  function vsIsBusy(n) { return !!root.vsPending[n] }
  function vsSetPending(n, entry) {
    var p = Object.assign({}, root.vsPending)
    if (entry) p[n] = entry; else delete p[n]
    root.vsPending = p
  }
  // Called after every status refresh: finish actions whose result is visible.
  function vsCheckPending() {
    var now = Date.now()
    for (var key in root.vsPending) {
      var n = parseInt(key, 10), e = root.vsPending[key], d = vsData(n)
      // The script holds the screen's lock until it's finished (d.busy).
      var done = !d.busy && (e.kind === "power" ? d.on === e.target
                                                : (d.audio === e.target && (!e.wasOn || d.on)))
      if (done) {
        vsSetPending(n, null)
        if (e.kind === "audio") {
          root.vsMsgFor = n
          root.vsMsgOk = true
          root.vsMsg = (e.target === "device" ? strings.t("sound.nowDevice") : strings.t("sound.nowLaptop"))
            + (e.wasOn ? " " + strings.t("sound.reconnect") : "")
        }
      } else if (now - e.started > 30000) {
        vsSetPending(n, null)
        if (e.kind === "audio") {
          root.vsMsgFor = n
          root.vsMsgOk = false
          root.vsMsg = strings.t("sound.failed")
        }
      }
    }
  }
  function vsShowsPairForm(n) {
    var d = vsData(n)
    return d.on && (d.devices.length === 0 || root.vsPairFormFor === n)
  }
  function vsIsOpen(n) {
    if (root.vsExpanded === n) return true
    if (root.vsHidden[n]) return false
    return vsShowsPairForm(n) || (root.vsMsgFor === n && root.vsMsg !== "") || !!vsData(n).error
  }
  function vsSetHidden(n, hidden) {
    var h = Object.assign({}, root.vsHidden)
    if (hidden) h[n] = true; else delete h[n]
    root.vsHidden = h
  }

  function run(args) { Quickshell.execDetached(["bash", root.vsCmd].concat(args)) }

  function vsToggle(n) {
    if (vsIsBusy(n) || !root.info.ready) return
    var on = vsData(n).on
    vsSetPending(n, { kind: "power", target: !on, wasOn: on, started: Date.now() })
    vsSetHidden(n, false)
    if (root.vsMsgFor === n) root.vsMsg = ""
    // Detached so Sunshine keeps running after this call returns.
    run([String(n), on ? "stop" : "start"])
  }
  function vsPair(n, pin, name) {
    if (pairProc.running) return
    root.vsPairingFor = n
    vsSetHidden(n, false)
    root.vsMsgFor = n
    root.vsMsg = strings.t("details.pairing")
    root.vsMsgOk = true
    // The PIN goes to the helper on stdin: arguments are visible to every
    // local account in /proc/<pid>/cmdline.
    root.vsPairPin = pin
    pairProc.command = ["bash", root.vsCmd, String(n), "pair", name]
    pairProc.running = true
  }
  function vsForget(n, uuid) {
    if (forgetProc.running) return
    root.vsForgetFor = n
    forgetProc.command = ["bash", root.vsCmd, String(n), "forget", uuid]
    forgetProc.running = true
  }
  function vsAudio(n, where) {
    var d = vsData(n)
    if (vsIsBusy(n) || d.audio === where) return
    vsSetPending(n, { kind: "audio", target: where, wasOn: d.on, started: Date.now() })
    if (root.vsMsgFor === n) root.vsMsg = ""
    run([String(n), "audio", where])
  }

  // System changes go through pkexec (the shell shows the password prompt).
  function runRoot(action, args) {
    if (rootProc.running) return
    root.rootRunning = true
    root.rootAction = action
    root.rootMsg = ""
    root.rootLog = ""
    root.rootNote = ""
    // setup installs from the plugin's files; trust/untrust use the root-owned copy.
    rootProc.command = (action !== "setup" && root.info.system)
      ? ["pkexec", root.rootHelperInstalled].concat(args)
      : ["pkexec", "bash", root.binDir + "/virtual-screen-root"].concat(args)
    rootProc.running = true
  }

  function refresh() { if (!infoProc.running) infoProc.running = true }

  // Opens a pre-filled GitHub issue in the browser; the user reviews it there.
  function reportRoot() {
    if (reportProc.running) return
    var title = (root.rootFailedAction === "setup" ? "Setup failed: " : "Wi-Fi change failed: ") + root.rootMsg
    reportProc.command = ["bash", root.vsCmd, "issue-url", title, root.rootLog]
    reportProc.running = true
  }
  function reportScreen(n) {
    if (reportProc.running) return
    reportProc.command = ["bash", root.vsCmd, String(n), "report"]
    reportProc.running = true
  }
  // Detached: the plugin removes itself at the end, which unloads this panel.
  function uninstall() {
    root.confirmUninstall = false
    root.uninstalling = true
    run(["uninstall"])
    uninstallReset.restart()
  }

  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    if (pt.y < flick.contentY) flick.contentY = Math.max(0, pt.y - 6)
    else if (pt.y + item.height > flick.contentY + flick.height)
      flick.contentY = pt.y + item.height - flick.height + 6
  }

  Component.onCompleted: refresh()

  // If the password prompt is dismissed the plugin stays; let the button work again.
  Timer {
    id: uninstallReset
    interval: 20000
    onTriggered: root.uninstalling = false
  }
  onOpenedChanged: if (opened) { refresh(); cursorActive = false; selectedIndex = 0 }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // While an action is in flight, re-check often so the row unlocks as soon
  // as it is done.
  Timer {
    interval: 700
    repeat: true
    running: Object.keys(root.vsPending).length > 0
    onTriggered: root.refresh()
  }

  Process {
    id: infoProc
    command: ["bash", root.vsCmd, "info-all"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.info = JSON.parse(String(text || "{}")) } catch (e) {}
        root.vsCheckPending()
      }
    }
  }

  Process {
    id: pairProc
    stdinEnabled: true
    stdout: StdioCollector { id: pairOut; waitForEnd: true }
    onStarted: {
      write(root.vsPairPin + "\n")
      root.vsPairPin = ""
    }
    onExited: function(exitCode) {
      root.vsPairPin = ""
      var out = String(pairOut.text || "").trim().split("\n")
      root.vsMsg = out[out.length - 1] || ""
      root.vsMsgOk = exitCode === 0
      if (exitCode === 0 && root.vsPairFormFor === root.vsPairingFor) root.vsPairFormFor = -1
      root.vsPairingFor = -1
      root.refresh()
    }
  }

  Process {
    id: forgetProc
    stdout: StdioCollector { id: forgetOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var out = String(forgetOut.text || "").trim().split("\n")
        root.vsMsgFor = root.vsForgetFor
        root.vsMsgOk = false
        root.vsMsg = out[out.length - 1] || strings.t("error.exit").arg(exitCode)
      }
      root.vsForgetFor = -1
      root.refresh()
    }
  }

  Process {
    id: rootProc
    stdout: StdioCollector { id: rootOut; waitForEnd: true }
    stderr: StdioCollector { id: rootErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.rootRunning = false
      var action = root.rootAction
      root.rootAction = ""
      var out = (String(rootOut.text || "") + "\n" + String(rootErr.text || "")).trim()
      var lines = out.split("\n").filter(function(l) { return l.trim() !== "" })
      if (exitCode === 0) {
        root.rootFailedAction = ""
        // e.g. "Set up. Turn USB tethering off and on once …"
        var last = lines.length ? lines[lines.length - 1] : ""
        if (action === "setup" && last.indexOf(". ") > 0) root.rootNote = last.substring(last.indexOf(". ") + 2)
      }
      // 126: the password prompt was dismissed; not a failure. (127 is
      // "not authorized" or an error, so it is reported.)
      if (exitCode !== 0 && exitCode !== 126) {
        root.rootMsg = lines.length ? lines[lines.length - 1] : strings.t("error.exit").arg(exitCode)
        root.rootLog = "exit code " + exitCode + "\n" + lines.slice(-40).join("\n")
        root.rootFailedAction = action
      }
      root.refresh()
    }
  }

  Process {
    id: reportProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var url = String(text || "").trim()
        if (url.indexOf("https://github.com/") === 0) Util.execArgv(["xdg-open", url])
      }
    }
  }

  // Shown under a failure: what went wrong, and a button that opens a
  // pre-filled GitHub issue.
  component FailureNote: Column {
    id: note
    property string message: ""
    signal report()
    visible: message !== ""
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    VsText {
      width: parent.width
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      color: Commons.Color.accent
      text: "✗ " + note.message
    }
    Button {
      text: strings.t("error.report")
      iconText: "󰊤"
      enabled: !reportProc.running
      opacity: enabled ? 1.0 : 0.6
      fontSize: Style.font.caption
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      bordered: true
      onClicked: note.report()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰹑"
    opacity: root.onCount > 0 ? 1.0 : 0.75
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(600))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.selectedIndex = Math.max(0, Math.min(root.vsNumbers.length - 1, root.selectedIndex + dy))
      }
      onActivateRequested: if (root.cursorActive) root.vsToggle(root.vsNumbers[root.selectedIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              text: "󰹑"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: strings.t("title")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: !root.info.ready ? strings.t("subtitle.setup")
                  : root.onCount > 0 ? strings.tn("subtitle.on", root.onCount).arg(Commons.I18n.formatNumber(root.onCount))
                  : strings.t("subtitle.off")
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 1
              }
            }
          }

          // ---------- One-time setup (or an update of the system part) ----------
          Column {
            visible: root.info.loaded === true && (!root.info.ready || root.info.update === true)
            width: parent.width
            spacing: Style.space(10)

            VsText {
              width: parent.width
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              text: root.info.ready ? strings.t("setup.updateText") : strings.t("setup.text")
            }
            Button {
              text: root.rootAction === "setup" ? strings.t("setup.running")
                : root.info.ready ? strings.t("setup.update") : strings.t("setup.button")
              iconText: root.rootAction === "setup" ? "󰑓" : ""
              iconSpinning: root.rootAction === "setup"
              enabled: !root.rootRunning
              opacity: enabled ? 1.0 : 0.6
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.runRoot("setup", ["setup"])
            }

            FailureNote {
              message: root.rootFailedAction === "setup" ? root.rootMsg : ""
              onReport: root.reportRoot()
            }
          }

          // ---------- Wi-Fi ----------
          Column {
            visible: root.info.loaded === true && root.info.ready && root.info.wifi !== null && root.info.wifi !== undefined
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.bar.foreground }
            PanelSectionHeader {
              text: strings.t("header.wifi")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Item {
              width: parent.width
              height: Math.max(wifiText.implicitHeight, wifiButton.implicitHeight)

              Column {
                id: wifiText
                anchors.left: parent.left
                anchors.right: wifiButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                VsText {
                  width: parent.width
                  font.pixelSize: Style.font.body
                  text: root.info.wifi ? root.info.wifi.name : ""
                }
                VsText {
                  width: parent.width
                  color: Qt.darker(root.bar.foreground, 1.4)
                  text: root.info.wifi && root.info.wifi.trusted ? strings.t("wifi.allowed") : strings.t("wifi.blocked")
                }
              }

              Button {
                id: wifiButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.rootAction === "wifi" ? strings.t("wifi.working")
                  : root.info.wifi && root.info.wifi.trusted ? strings.t("wifi.disallow") : strings.t("wifi.allow")
                iconText: root.rootAction === "wifi" ? "󰑓" : ""
                iconSpinning: root.rootAction === "wifi"
                enabled: !root.rootRunning
                opacity: enabled ? 1.0 : 0.6
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: root.info.wifi && root.info.wifi.trusted
                onClicked: if (root.info.wifi) root.runRoot("wifi", [root.info.wifi.trusted ? "untrust-wifi" : "trust-wifi", root.info.wifi.uuid])
              }
            }

            FailureNote {
              message: root.rootFailedAction === "wifi" ? root.rootMsg : ""
              onReport: root.reportRoot()
            }
          }

          // ---------- Screens ----------
          Column {
            visible: root.info.loaded === true && root.info.ready
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.bar.foreground }
            PanelSectionHeader {
              text: strings.t("header.screens")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            VsText {
              visible: root.rootNote !== ""
              width: parent.width
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              text: "ⓘ " + root.rootNote
            }

            Repeater {
              model: root.vsNumbers
              VirtualScreenBlock {
                required property int modelData
                required property int index
                width: panelColumn.width
                screenNumber: modelData
                rowIndex: index
              }
            }
          }

          // ---------- Uninstall ----------
          Column {
            visible: root.info.loaded === true
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.bar.foreground }

            Button {
              visible: !root.confirmUninstall
              text: root.uninstalling ? strings.t("uninstall.running") : strings.t("uninstall.button")
              iconText: root.uninstalling ? "󰑓" : ""
              iconSpinning: root.uninstalling
              enabled: !root.uninstalling && !root.rootRunning
              opacity: enabled ? 1.0 : 0.6
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.confirmUninstall = true
            }

            Column {
              visible: root.confirmUninstall
              width: parent.width
              spacing: Style.space(6)

              VsText {
                width: parent.width
                wrapMode: Text.WordWrap
                elide: Text.ElideNone
                text: strings.t("uninstall.confirm")
              }
              Row {
                spacing: Style.space(6)
                Button {
                  text: strings.t("uninstall.yes")
                  fontSize: Style.font.caption
                  foreground: Commons.Color.accent
                  fontFamily: root.bar.fontFamily
                  bordered: true
                  onClicked: root.uninstall()
                }
                Button {
                  text: strings.t("uninstall.cancel")
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  bordered: true
                  onClicked: root.confirmUninstall = false
                }
              }
            }
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  component VsText: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  component VirtualScreenBlock: Column {
    id: block
    required property int screenNumber
    required property int rowIndex
    readonly property var sd: root.vsData(screenNumber)
    readonly property bool busy: root.vsIsBusy(screenNumber)
    readonly property var pending: root.vsPendingOf(screenNumber)
    readonly property bool powerPending: pending !== null && pending.kind === "power"
    readonly property string audioTarget: pending !== null && pending.kind === "audio" ? pending.target : ""
    // What the Sound buttons show: the choice in flight, else the real setting.
    readonly property string audioShown: audioTarget !== "" ? audioTarget : (sd.audio || "laptop")
    readonly property bool expanded: root.vsExpanded === screenNumber
    readonly property bool open: root.vsIsOpen(screenNumber)
    readonly property color dim: Qt.darker(root.bar.foreground, 1.4)
    readonly property real labelWidth: Style.space(56)   // USB / Wi-Fi / Paired / Sound
    spacing: Style.space(4)

    CursorSurface {
      id: row
      width: parent.width
      hasCursor: root.cursorActive && root.selectedIndex === block.rowIndex
      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(row)
      current: block.sd.on
      foreground: root.bar.foreground
      fill: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
      currentFill: Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
      implicitHeight: rowInner.implicitHeight + Style.spacing.xl
      opacity: block.powerPending ? 0.6 : 1.0

      // Declared first so the arrow's own MouseArea sits on top of it.
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.selectedIndex = block.rowIndex }
        onClicked: root.vsToggle(block.screenNumber)
      }

      Row {
        id: rowInner
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(2)
        spacing: Style.space(8)

        Text {
          text: "󰍹"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: {
            var names = (block.sd.devices || []).map(function(d) { return d.name }).join(", ")
            return root.vsTitle(block.screenNumber) + (names ? " · " + names : "")
          }
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width - Style.space(22) - stateText.width - arrow.width - Style.space(8) * 3
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: stateText
          textFormat: Text.PlainText
          text: block.powerPending ? (block.sd.on ? strings.t("state.stopping") : strings.t("state.starting"))
                           : (block.sd.on ? strings.t("state.on") + "  󰄬" : strings.t("state.off"))
          color: block.sd.on ? root.bar.foreground : block.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          width: Style.space(72)
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
        }

        // Dropdown arrow: opens the details below the row.
        Text {
          id: arrow
          text: block.open ? "󰅃" : "󰅀"
          color: arrowMouse.containsMouse ? Commons.Color.accent : root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          width: Style.space(26)
          height: Style.space(26)
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          anchors.verticalCenter: parent.verticalCenter

          MouseArea {
            id: arrowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var n = block.screenNumber
              if (block.open) {
                if (root.vsExpanded === n) root.vsExpanded = -1
                if (root.vsPairFormFor === n) root.vsPairFormFor = -1
                if (root.vsMsgFor === n) root.vsMsg = ""
                root.vsSetHidden(n, true)
              } else {
                root.vsSetHidden(n, false)
                root.vsExpanded = n
              }
            }
          }
        }
      }
    }

    // ---------- details ----------
    Rectangle {
      visible: block.open
      width: parent.width
      implicitHeight: details.implicitHeight + Style.space(20)
      color: "transparent"
      radius: Style.space(6)
      border.width: 1
      border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.18)

      Column {
        id: details
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(10)
        spacing: Style.space(8)

        FailureNote {
          message: block.sd.error || ""
          onReport: root.reportScreen(block.screenNumber)
        }

        VsText {
          visible: !block.sd.on && !block.sd.error
          width: parent.width
          color: block.dim
          text: strings.t("details.off")
        }

        // Where the device connects.
        Column {
          visible: block.sd.on
          width: parent.width
          spacing: Style.space(3)

          VsText {
            width: parent.width
            color: block.dim
            text: (block.sd.addresses || []).length > 0 ? strings.t("details.addPc") : strings.t("details.noConnection")
            wrapMode: Text.WordWrap
            elide: Text.ElideNone
          }

          Repeater {
            model: block.sd.addresses || []
            Row {
              required property var modelData
              spacing: Style.space(10)
              VsText { width: block.labelWidth; color: block.dim; text: modelData.kind }
              VsText { font.bold: true; text: modelData.addr }
            }
          }
        }

        // PIN entry.
        Column {
          visible: root.vsShowsPairForm(block.screenNumber)
          width: parent.width
          spacing: Style.space(6)

          VsText { color: block.dim; text: strings.t("details.typePin") }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: pinField
              width: Style.space(80)
              placeholderText: strings.t("details.pin")
              maximumLength: 4
              inputMethodHints: Qt.ImhDigitsOnly
              validator: RegularExpressionValidator { regularExpression: /[0-9]{0,4}/ }
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              enabled: root.vsPairingFor !== block.screenNumber
              onAccepted: if (text.length === 4) root.vsPair(block.screenNumber, text, nameField.text.trim())
              onVisibleChanged: if (!visible) text = ""
            }

            TextField {
              id: nameField
              width: parent.width - pinField.width - pairButton.width - Style.space(6) * 2
              placeholderText: strings.t("details.deviceName")
              maximumLength: 32
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              enabled: root.vsPairingFor !== block.screenNumber
              onAccepted: if (pinField.text.length === 4) root.vsPair(block.screenNumber, pinField.text, text.trim())
              onVisibleChanged: if (!visible) text = ""
            }

            Button {
              id: pairButton
              text: root.vsPairingFor === block.screenNumber ? "…" : strings.t("details.pair")
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              enabled: !pairProc.running
              opacity: pinField.text.length === 4 && enabled ? 1.0 : 0.45
              anchors.verticalCenter: parent.verticalCenter
              onClicked: if (pinField.text.length === 4) root.vsPair(block.screenNumber, pinField.text, nameField.text.trim())
            }
          }
        }

        // Result of the last pairing on this screen.
        VsText {
          visible: root.vsMsgFor === block.screenNumber && root.vsMsg !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          elide: Text.ElideNone
          color: root.vsMsgOk ? root.bar.foreground : Commons.Color.accent
          text: (root.vsPairingFor === block.screenNumber ? "" : (root.vsMsgOk ? "✓ " : "✗ ")) + root.vsMsg
        }

        // Paired devices and sound: only when opened with the arrow.
        Column {
          visible: block.expanded
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: block.expanded ? (block.sd.devices || []) : []
            Item {
              required property var modelData
              required property int index
              width: details.width
              height: forgetButton.implicitHeight
              VsText {
                id: pairedLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: block.labelWidth
                color: block.dim
                text: index === 0 ? strings.t("details.paired") : ""
              }
              VsText {
                anchors.left: pairedLabel.right
                anchors.leftMargin: Style.space(10)
                anchors.right: forgetButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.name
              }
              Button {
                id: forgetButton
                anchors.right: parent.right
                text: root.vsForgetFor === block.screenNumber ? "…" : strings.t("details.forget")
                enabled: !forgetProc.running
                opacity: enabled ? 1.0 : 0.5
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.vsForget(block.screenNumber, modelData.uuid)
              }
            }
          }

          Column {
            visible: block.sd.on && (block.sd.devices || []).length > 0 && root.vsPairFormFor !== block.screenNumber
            x: block.labelWidth + Style.space(10)
            width: parent.width - x
            spacing: Style.space(3)

            Button {
              text: strings.t("details.pairDifferent")
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: { root.vsPairFormFor = block.screenNumber; root.vsMsg = "" }
            }

            VsText {
              width: parent.width
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              color: block.dim
              font.pixelSize: Style.font.caption
              text: {
                var others = root.vsNumbers.filter(function(m) { return m !== block.screenNumber })
                return strings.t("details.pairDifferentHint")
                  .arg(strings.t("details.or").arg(root.vsTitle(others[0])).arg(root.vsTitle(others[1])))
              }
            }
          }

          Row {
            spacing: Style.space(6)
            VsText {
              width: block.labelWidth + Style.space(4)
              color: block.dim
              text: strings.t("details.sound")
              anchors.verticalCenter: parent.verticalCenter
            }
            Button {
              text: strings.t("details.laptop")
              iconText: block.audioTarget === "laptop" ? "󰑓" : ""
              iconSpinning: block.audioTarget === "laptop"
              enabled: !block.busy
              opacity: enabled || block.audioTarget === "laptop" ? 1.0 : 0.5
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              active: block.audioShown === "laptop"
              onClicked: root.vsAudio(block.screenNumber, "laptop")
            }
            Button {
              text: strings.t("details.device")
              iconText: block.audioTarget === "device" ? "󰑓" : ""
              iconSpinning: block.audioTarget === "device"
              enabled: !block.busy
              opacity: enabled || block.audioTarget === "device" ? 1.0 : 0.5
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              active: block.audioShown === "device"
              onClicked: root.vsAudio(block.screenNumber, "device")
            }
          }
        }
      }
    }
  }
}
