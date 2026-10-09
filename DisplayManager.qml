import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "DisplayModel.js" as DisplayModel

Panel {
  id: root
  moduleName: "io.github.bmontythe3rd.display-manager"
  ipcTarget: moduleName

  property var displays: []
  property int selectedIndex: 0
  // Set when the panel opens; the next state read then selects the focused
  // display instead of keeping the previous index (0 on first load, which is
  // whichever display Hyprland lists first, usually the internal panel).
  property bool selectFocusedOnState: true
  property bool loading: false
  property bool applying: false
  property bool awaitingConfirmation: false
  property int secondsRemaining: 15
  property string statusMessage: ""
  property string refreshMessage: ""
  property string helperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + moduleName + "/bin/display-manager"

  readonly property var selectedDisplay: displays.length && selectedIndex < displays.length ? displays[selectedIndex] : null
  readonly property int activeCount: displays.filter(function(d) { return !d.disabled }).length
  readonly property bool validLayout: activeCount > 0 && !DisplayModel.hasOverlap(displays)

  function parseOutput(text) {
    try { return JSON.parse(String(text || "")) } catch (e) { return null }
  }

  function processError(text, fallback) {
    var parsed = parseOutput(text)
    return parsed && parsed.error ? parsed.error : fallback
  }

  function refresh(message) {
    if (stateProc.running) {
      if (message) refreshMessage = message
      return
    }
    refreshMessage = message || ""
    loading = true
    stateProc.command = [helperPath, "state"]
    stateProc.running = true
  }

  function updateDisplay(key, value) {
    if (!selectedDisplay) return
    var copy = DisplayModel.clone(displays)
    copy[selectedIndex][key] = value
    if (key === "mode") {
      var scales = DisplayModel.validScales(value)
      if (scales.indexOf(Number(copy[selectedIndex].scale)) < 0) copy[selectedIndex].scale = scales[0]
    }
    displays = copy
  }

  function setResolution(value) {
    if (!selectedDisplay) return
    updateDisplay("mode", DisplayModel.nearestMode(selectedDisplay.modes, value, DisplayModel.refresh(selectedDisplay.mode)))
  }

  function setRefresh(value) {
    if (!selectedDisplay) return
    updateDisplay("mode", DisplayModel.nearestMode(selectedDisplay.modes, DisplayModel.resolution(selectedDisplay.mode), value))
  }

  function toggleEnabled() {
    if (!selectedDisplay || (!selectedDisplay.disabled && activeCount <= 1)) return
    updateDisplay("disabled", !selectedDisplay.disabled)
  }

  function applyPreview() {
    if (!validLayout || applying) return
    applying = true
    statusMessage = "Applying preview…"
    applyProc.command = [helperPath, "preview", JSON.stringify(DisplayModel.normalizePositions(displays))]
    applyProc.running = true
  }

  function confirmChanges() {
    if (confirmProc.running || revertProc.running) return
    confirmProc.command = [helperPath, "confirm"]
    confirmProc.running = true
  }

  function revertChanges() {
    if (revertProc.running || confirmProc.running) return
    statusMessage = "Restoring previous layout…"
    revertProc.command = [helperPath, "revert"]
    revertProc.running = true
  }

  function saveDefault() {
    saveProc.command = [helperPath, "profiles-save", "Default", JSON.stringify(DisplayModel.normalizePositions(displays)), "true"]
    saveProc.running = true
  }

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) { selectFocusedOnState = true; refresh() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱀅"
    tooltipText: "Display Manager"
    active: root.awaitingConfirmation
    onPressed: function(mouseButton) { root.toggle() }
  }

  Process {
    id: stateProc
    property bool outputValid: false
    stderr: StdioCollector { id: stateError; waitForEnd: true }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = root.parseOutput(text)
        if (parsed && Array.isArray(parsed)) {
          stateProc.outputValid = true
          root.displays = parsed
          if (root.selectFocusedOnState) {
            root.selectFocusedOnState = false
            for (var i = 0; i < parsed.length; i++) {
              if (parsed[i].focused === true) { root.selectedIndex = i; break }
            }
          }
          if (root.selectedIndex >= parsed.length) root.selectedIndex = Math.max(0, parsed.length - 1)
          root.statusMessage = root.refreshMessage
          root.refreshMessage = ""
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 || !outputValid) {
        root.statusMessage = root.processError(stateError.text, "Could not read Hyprland display state")
        root.refreshMessage = ""
      }
    }
    onRunningChanged: {
      if (running) outputValid = false
      else root.loading = false
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyOutput; waitForEnd: true }
    stderr: StdioCollector { id: applyError; waitForEnd: true }
    onExited: function(exitCode) {
      root.applying = false
      if (exitCode === 0) {
        var result = root.parseOutput(applyOutput.text)
        root.awaitingConfirmation = true
        root.secondsRemaining = result && result.timeout ? Number(result.timeout) : 15
        root.statusMessage = "Keep these display settings?"
        confirmationTimer.restart()
      } else {
        root.refresh(root.processError(applyError.text, "Preview failed; the previous layout was restored"))
      }
    }
  }

  Process {
    id: confirmProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: confirmError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.awaitingConfirmation = false
        confirmationTimer.stop()
        root.statusMessage = "Saving this layout for the connected display set…"
        root.saveDefault()
      } else {
        root.statusMessage = root.processError(confirmError.text, "Could not confirm display settings; automatic rollback is still active")
      }
    }
  }

  Process {
    id: revertProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: revertError; waitForEnd: true }
    onExited: function(exitCode) {
      root.awaitingConfirmation = false
      confirmationTimer.stop()
      if (exitCode === 0)
        root.refresh("Previous layout restored")
      else
        root.refresh(root.processError(revertError.text, "Previous layout could not be restored"))
    }
  }

  Process {
    id: saveProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: saveError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0)
        root.refresh("Display settings kept and saved for this display set")
      else
        root.refresh(root.processError(saveError.text, "Display settings were kept, but the automatic profile could not be saved"))
    }
  }

  Timer {
    id: confirmationTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.secondsRemaining--
      if (root.secondsRemaining <= 0) {
        stop()
        root.statusMessage = "Timed out; restoring previous layout…"
        root.revertChanges()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    centerOnBar: true
    // These are viewport dimensions, not spacing tokens. Running them through
    // Style.space() made the whole card balloon when the user chose large text.
    contentWidth: panel.fittedContentWidth(Math.min(760, panel.availableCardWidth))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Math.min(780, panel.availableCardHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
          id: contentColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          RowLayout {
            width: parent.width
            spacing: Style.space(12)
            Text {
              text: "󰍺"
              color: root.barForeground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
            }
            Column {
              Layout.fillWidth: true
              Text { width: parent.width; text: "Display Manager"; color: root.barForeground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight }
              Text { width: parent.width; text: root.displays.length + (root.displays.length === 1 ? " DISPLAY CONNECTED" : " DISPLAYS CONNECTED"); color: Qt.darker(root.barForeground, 1.4); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.1; elide: Text.ElideRight }
            }
            Button {
              Layout.alignment: Qt.AlignVCenter
              text: "Identify"
              foreground: root.barForeground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: if (root.bar && root.bar.shell) root.bar.shell.summon(root.moduleName, JSON.stringify({ displays: root.displays }))
            }
          }

          PanelSeparator { foreground: root.barForeground }

          Text {
            visible: root.loading || root.displays.length === 0
            width: parent.width
            text: root.loading ? "Reading displays…" : "No displays were reported by Hyprland."
            color: root.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Rectangle {
            id: layoutCanvas
            visible: root.displays.length > 0
            width: parent.width
            height: Math.min(240, Math.max(170, panel.contentWidth * 0.31))
            radius: Style.cornerRadius
            color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.035)
            border.color: root.validLayout ? Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.18) : Color.urgent
            border.width: 1

            property real minX: {
              var v = Infinity; root.displays.forEach(function(d) { if (!d.disabled && !d.mirror) v = Math.min(v, d.x) }); return isFinite(v) ? v : 0
            }
            property real minY: {
              var v = Infinity; root.displays.forEach(function(d) { if (!d.disabled && !d.mirror) v = Math.min(v, d.y) }); return isFinite(v) ? v : 0
            }
            property real maxX: {
              var v = 1; root.displays.forEach(function(d) { var s=DisplayModel.logicalSize(d); if (!d.disabled && !d.mirror) v=Math.max(v,d.x+s.width) }); return v
            }
            property real maxY: {
              var v = 1; root.displays.forEach(function(d) { var s=DisplayModel.logicalSize(d); if (!d.disabled && !d.mirror) v=Math.max(v,d.y+s.height) }); return v
            }
            property real zoom: Math.min((width - Style.space(32)) / Math.max(1, maxX-minX), (height - Style.space(32)) / Math.max(1, maxY-minY))

            Repeater {
              model: root.displays
              Rectangle {
                required property var modelData
                required property int index
                property var logical: DisplayModel.logicalSize(modelData)
                visible: !modelData.disabled
                x: Style.space(16) + (modelData.x - layoutCanvas.minX) * layoutCanvas.zoom
                y: Style.space(16) + (modelData.y - layoutCanvas.minY) * layoutCanvas.zoom
                width: Math.max(Style.space(70), logical.width * layoutCanvas.zoom)
                height: Math.max(Style.space(44), logical.height * layoutCanvas.zoom)
                radius: Style.cornerRadius
                color: index === root.selectedIndex ? Style.selectedFillFor(root.barForeground, Color.accent) : Style.hoverFillFor(root.barForeground, Color.accent)
                border.color: index === root.selectedIndex ? Color.accent : root.barForeground
                border.width: index === root.selectedIndex ? 2 : 1
                opacity: modelData.mirror ? 0.65 : 1

                Text {
                  anchors.centerIn: parent
                  text: (index + 1) + "  " + modelData.name + (modelData.mirror ? "\nMirrors " + modelData.mirror : "")
                  color: root.barForeground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  horizontalAlignment: Text.AlignHCenter
                }
                MouseArea {
                  anchors.fill: parent
                  drag.target: parent
                  drag.axis: Drag.XAndYAxis
                  cursorShape: Qt.SizeAllCursor
                  onPressed: root.selectedIndex = index
                  onReleased: {
                    var copy = DisplayModel.clone(root.displays)
                    copy[index].x = Math.round((parent.x - Style.space(16)) / layoutCanvas.zoom + layoutCanvas.minX)
                    copy[index].y = Math.round((parent.y - Style.space(16)) / layoutCanvas.zoom + layoutCanvas.minY)
                    root.displays = copy
                  }
                }
              }
            }
          }

          Text {
            visible: !root.validLayout
            text: root.activeCount === 0 ? "At least one display must stay enabled." : "Displays cannot overlap. Drag them apart before applying."
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { visible: root.displays.length > 0; foreground: root.barForeground }

          Flow {
            visible: root.displays.length > 0
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: root.displays
              Button {
                required property var modelData
                required property int index
                text: (index + 1) + " · " + modelData.name
                foreground: root.barForeground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: index === root.selectedIndex
                onClicked: root.selectedIndex = index
              }
            }
          }

          GridLayout {
            visible: root.selectedDisplay !== null
            width: parent.width
            columns: width >= 680 ? 4 : 2
            columnSpacing: Style.space(10)
            rowSpacing: Style.space(10)

            Dropdown {
              id: resolutionDropdown
              Layout.fillWidth: true
              label: options.length === 1 ? "RESOLUTION · NATIVE" : "RESOLUTION"
              foreground: root.barForeground; fontFamily: root.bar.fontFamily
              options: root.selectedDisplay ? DisplayModel.resolutionOptions(root.selectedDisplay.modes) : []
              value: root.selectedDisplay ? DisplayModel.resolution(root.selectedDisplay.mode) : ""
              enabled: options.length > 1
              opacity: enabled ? 1 : 0.72
              onChanged: function(value) { root.setResolution(value) }
            }
            Dropdown {
              Layout.fillWidth: true
              label: "REFRESH RATE"
              foreground: root.barForeground; fontFamily: root.bar.fontFamily
              options: root.selectedDisplay ? DisplayModel.refreshOptions(root.selectedDisplay.modes, DisplayModel.resolution(root.selectedDisplay.mode)) : []
              value: root.selectedDisplay ? DisplayModel.refresh(root.selectedDisplay.mode) : ""
              onChanged: function(value) { root.setRefresh(value) }
            }
            Dropdown {
              Layout.fillWidth: true
              label: "ORIENTATION"
              foreground: root.barForeground; fontFamily: root.bar.fontFamily
              options: [{value:"0",label:"Landscape"},{value:"1",label:"Portrait"},{value:"2",label:"Landscape flipped"},{value:"3",label:"Portrait flipped"}]
              value: root.selectedDisplay ? String(root.selectedDisplay.transform) : "0"
              onChanged: function(value) { root.updateDisplay("transform", Number(value)) }
            }
            Dropdown {
              Layout.fillWidth: true
              label: "SCALE"
              foreground: root.barForeground; fontFamily: root.bar.fontFamily
              options: root.selectedDisplay ? DisplayModel.validScales(root.selectedDisplay.mode).map(function(v){return {value:String(v),label:Math.round(v*100)+"%"}}) : []
              value: root.selectedDisplay ? String(root.selectedDisplay.scale) : "1"
              onChanged: function(value) { root.updateDisplay("scale", Number(value)) }
            }
          }

          RowLayout {
            visible: root.selectedDisplay !== null
            width: parent.width
            spacing: Style.space(10)
            Dropdown {
              Layout.fillWidth: true
              label: "MULTIPLE DISPLAYS"
              foreground: root.barForeground; fontFamily: root.bar.fontFamily
              options: [{value:"",label:"Extend desktop"}].concat(root.displays.filter(function(d){return root.selectedDisplay && d.name !== root.selectedDisplay.name && !d.disabled}).map(function(d){return {value:d.name,label:"Duplicate " + d.name}}))
              value: root.selectedDisplay ? root.selectedDisplay.mirror : ""
              onChanged: function(value) { root.updateDisplay("mirror", value) }
            }
            Button {
              Layout.alignment: Qt.AlignBottom
              text: root.selectedDisplay && root.selectedDisplay.disabled ? "Connect display" : "Disconnect display"
              foreground: root.barForeground; fontFamily: root.bar.fontFamily; bordered: true
              enabled: root.selectedDisplay && (root.selectedDisplay.disabled || root.activeCount > 1)
              onClicked: root.toggleEnabled()
            }
          }

          PanelSeparator { foreground: root.barForeground }

          RowLayout {
            width: parent.width
            spacing: Style.space(10)
            Text {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              text: root.statusMessage || "Preview changes safely for 15 seconds."
              color: root.awaitingConfirmation ? Color.accent : Qt.darker(root.barForeground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Button {
              id: refreshButton
              Layout.alignment: Qt.AlignVCenter
              text: "Refresh"
              foreground: root.barForeground; fontFamily: root.bar.fontFamily; bordered: true
              onClicked: root.refresh()
            }
            Button {
              id: applyButton
              Layout.alignment: Qt.AlignVCenter
              text: root.applying ? "Applying…" : "Apply"
              foreground: root.barForeground; fontFamily: root.bar.fontFamily; bordered: true
              active: true
              enabled: root.validLayout && !root.applying && !root.awaitingConfirmation
              onClicked: root.applyPreview()
            }
          }

          RowLayout {
            visible: root.awaitingConfirmation
            width: parent.width
            spacing: Style.space(10)
            Text { text: root.secondsRemaining + "s"; color: Color.accent; font.family: root.bar.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true; Layout.alignment: Qt.AlignVCenter }
            Item { Layout.fillWidth: true; height: 1 }
            Button { id: revertButton; text: revertProc.running ? "Reverting…" : "Revert"; foreground: root.barForeground; fontFamily: root.bar.fontFamily; bordered: true; enabled: !confirmProc.running && !revertProc.running; onClicked: root.revertChanges() }
            Button { id: keepButton; text: confirmProc.running ? "Keeping…" : "Keep changes"; foreground: root.barForeground; fontFamily: root.bar.fontFamily; bordered: true; active: true; enabled: !confirmProc.running && !revertProc.running; onClicked: root.confirmChanges() }
          }
        }
      }
    }
  }
}
