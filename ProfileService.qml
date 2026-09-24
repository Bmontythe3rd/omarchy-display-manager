import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  property string moduleName: "io.github.bmontythe3rd.display-manager"
  property string helperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + moduleName + "/bin/display-manager"
  property string lastTopology: ""
  property string pendingTopology: ""

  function checkTopology() {
    if (!topologyProc.running) {
      topologyProc.command = [helperPath, "topology"]
      topologyProc.running = true
    }
  }

  Component.onCompleted: checkTopology()

  Timer { interval: 4000; running: true; repeat: true; onTriggered: root.checkTopology() }

  Process {
    id: topologyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root) return
        var value = String(text || "").trim()
        if (!value || value === root.lastTopology) return
        if (matchProc.running) return
        root.pendingTopology = value
        matchProc.activeTopology = value
        matchProc.command = [root.helperPath, "profiles-match"]
        matchProc.running = true
      }
    }
  }

  Process {
    id: matchProc
    property string activeTopology: ""

    function handleResult(rawJson) {
      if (!root || !activeTopology) return
      try {
        var result = JSON.parse(String(rawJson || "{}"))
        if (result.ok === true) {
          root.lastTopology = activeTopology
        }
        if (result.matched) {
          Quickshell.execDetached(["omarchy-notification-send", "-g", "󰍺", "Display profile applied", result.name])
        }
      } catch (e) {}
    }

    stdout: StdioCollector {
      id: matchOutput
      waitForEnd: true
      onStreamFinished: matchProc.handleResult(text)
    }
    stderr: StdioCollector { id: matchError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var detail = String(matchError.text || "").trim()
        console.warn("Display profile match failed" + (detail ? ": " + detail : ""))
      } else if (root.lastTopology !== activeTopology) {
        matchProc.handleResult(matchOutput.text)
      }
      if (root) root.pendingTopology = ""
    }
  }
}
