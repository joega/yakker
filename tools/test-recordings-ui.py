#!/usr/bin/env python3
"""Optional Omarchy native UI smoke test; never touches installed configuration.

Requires Go, quickshell, installed Omarchy qs.Ui/Commons, FFmpeg with libopus,
ffprobe, and mpv. Uses isolated data, a local fixture, and mpv's null audio sink.
Run on a host that permits local Unix sockets. Output screenshots go to --output.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SMOKE = ROOT / "tools/qml-smoke"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("/tmp/yakker-recordings-ui-qa"))
    parser.add_argument("--compact", action="store_true", help="Audit all views with native popup padding, narrow widths, and short heights")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
    for binary in ("go", "quickshell", "ffmpeg", "ffprobe", "mpv"):
        if not shutil.which(binary):
            raise SystemExit("Missing dependency: " + binary)
    if not (shell / "Ui/Button.qml").exists():
        raise SystemExit("Omarchy qs.Ui components are required: " + str(shell))

    with tempfile.TemporaryDirectory(prefix="yakker-recordings-ui-") as tmp:
        base = Path(tmp)
        plugin, imports, runtime, data, config, media, bin_dir, cache = [base / n for n in ("plugin", "imports", "runtime", "data", "config", "media", "bin", "cache")]
        for p in (plugin, imports, runtime, data, config, media, bin_dir, cache):
            p.mkdir()
        runtime.chmod(0o700)
        qs = imports / "qs"
        qs.mkdir()
        shutil.copytree(shell / "Ui", qs / "Ui", symlinks=False)
        if args.compact:
            wrapper = (ROOT / "tools/readme/KeyboardPanel.qml").read_text()
            wrapper = wrapper.replace("width: contentWidth", "width: Math.min(contentWidth, owner.width)")
            wrapper = wrapper.replace("height: contentHeight", "height: Math.min(contentHeight, owner.height)")
            wrapper = wrapper.replace("return Math.ceil(value + card.contentTopInset + card.contentBottomInset)", "return Math.min(owner.height, Math.ceil(value + card.contentTopInset + card.contentBottomInset))")
            wrapper = wrapper.replace("function fittedContentWidth(value) { return value }", "function fittedContentWidth(value) { return Math.min(value, owner.width) }")
            (qs / "Ui/KeyboardPanel.qml").write_text(wrapper)
        else:
            shutil.copy2(SMOKE / "KeyboardPanel.qml", qs / "Ui/KeyboardPanel.qml")
        for name in ("Commons", "services"):
            (qs / name).symlink_to(shell / name, target_is_directory=True)
        for name in ("BarWidget.qml", "Panel.qml", "RadioService.qml", "RecordingNotices.js", "StationLogo.qml", "RecordingsView.qml", "FocusButton.qml", "FocusIcon.qml", "StationPicker.qml", "MarqueeText.qml", "StateCard.qml", "FocusTextField.qml", "FocusDropdown.qml", "FocusSlider.qml", "qmldir"):
            shutil.copy2(ROOT / name, plugin / name)
        (plugin / "assets").symlink_to(ROOT / "assets", target_is_directory=True)
        bar_widget = plugin / "BarWidget.qml"
        bar_widget.write_text(bar_widget.read_text().replace('  property bool attached: false', '''  property alias testButton: button
  property alias testStateIcon: stateIcon
  property alias testLogo: stationLogo
  property alias testRecordingIndicator: recordingIndicator
  property bool attached: false''', 1))
        dropdown = plugin / "FocusDropdown.qml"
        dropdown.write_text(dropdown.read_text().replace('  id: root', '''  id: root
  property alias testTrigger: trigger
  property alias testLabel: triggerLabel
  property alias testSearch: search
  property alias testResults: results
  property alias testPopup: popup''', 1))
        field = plugin / "FocusTextField.qml"
        field.write_text(field.read_text().replace('  id: root', '  id: root\n  property alias testClear: clearButton', 1))
        panel = plugin / "Panel.qml"
        panel.write_text(panel.read_text().replace('  property var anchorItem: null', '''  property alias testBody: panelContent
  property alias testPlayerStatus: playerStatus
  property alias testDockStatus: dockStatus
  property alias testPlaybackHint: playbackHintText
  property alias testTimeline: timelineSlider
  property alias testFileTimeline: fileTimeline
  property alias testVolume: volumeSlider
  property alias testVolumeLabel: volumeLabel
  property alias testMute: muteButton
  property alias testConnectionState: connectionState
  property alias testDockRetry: dockRetry
  property alias testView: recordingsView
  property alias testCatcher: keyCatcher
  property alias testListenButton: listenButton
  property alias testSchedulesButton: schedulesButton
  property alias testBufferPresets: bufferPresets
  property alias testBufferSummary: bufferSummary
  property alias testBufferDescription: bufferDescription
  property alias testShortcuts: shortcutGrid
  property alias testRecordingsButton: recordingsButton
  property alias testSettingsTabs: settingsTabs
  property alias testStationList: customStations
  property alias testSettings: settingsView
  property alias testPlayerView: playerView
  property alias testSettingsButton: settingsButton
  property alias testSettingsClose: settingsCloseButton
  property alias testDock: playbackDock
  property alias testDockPlay: dockPlay
  property alias testDockBack: dockBack
  property alias testDockForward: dockForward
  property alias testDockStop: dockStop
  property alias testScroller: scroller
  property alias testPresets: presetRepeater
  property alias testHeading: stationHeading
  property alias testPlayButton: playButton
  property alias testStopButton: stopButton
  property alias testBackButton: backButton
  property alias testForwardButton: forwardButton
  property alias testFavoriteButton: favoriteButton
  property alias testSpeedPicker: speedPicker
  property alias testSleepButton: sleepButton
  property alias testSleepPopup: sleepPopup
  property alias testSleepPresets: sleepPresets
  property alias testSleepCountdown: sleepCountdown
  property alias testSleepOff: sleepOff
  property alias testSleepMinutes: sleepMinutes
  property alias testStationPicker: stationPicker
  property alias testStationURL: stationURL
  property alias testStationCity: stationCity
  property alias testStationCountry: stationCountry
  property alias testStationWebsite: stationWebsite
  property alias testStationSave: saveStationButton
  property alias testStationCancel: cancelStationButton
  property alias testStationDelete: deleteStationButton
  property alias testName: stationName
  property var anchorItem: null''', 1))
        panel.write_text(panel.read_text().replace('                    id: customStationRow', '                    id: customStationRow\n                    property alias testTitle: customStationTitle\n                    property alias testEdit: customStationEdit', 1))
        view = plugin / "RecordingsView.qml"
        view.write_text(view.read_text().replace('  required property var radio', '''  property alias testEmptyLibrary: emptyLibrary
  property alias testUnavailable: recordingsUnavailable
  property alias testSchedules: scheduleRepeater
  property alias testEnabled: scheduleEnabledToggle
  property alias testZone: zoneField
  property alias testSaveSchedule: saveScheduleButton
  property alias testDeleteSchedule: deleteScheduleButton
  property alias testStartNow: startNowButton
  property alias testDate: dateField
  property alias testDuration: durationField
  property alias testSearch: searchField
  property alias testStatus: statusPicker
  property alias testStationPicker: stationPicker
  property alias testLibrary: libraryRepeater
  property alias testLabel: labelField
  property alias testStart: startField
  property alias testEnd: endField
  property alias testStartPadding: startPadding
  property alias testEndPadding: endPadding
  property alias testStorageContent: storageSettings
  property alias testAlertsContent: notificationSettings
  property alias testRecordingAlerts: recordingAlertsToggle
  property alias testRecordingStarts: recordingStartToggle
  property alias testStorageUsage: storageUsage
  property alias testCap: capField
  property alias testStorageSave: saveStorageButton
  property alias testStorageCancel: cancelStorageButton
  property alias testStorageRefresh: refreshStorageButton
  property alias testOpenFolder: openFolderButton
  property alias testFolder: folderField
  property alias testRefreshDraft: refreshDraftButton
  required property var radio''', 1))
        view.write_text(view.read_text().replace('        id: recordRow', """        id: recordRow
        property alias testPrimary: rowPrimary
        property alias testDetails: rowDetails
        property alias testDelete: rowDelete
        property alias testRestart: rowRestart
        property alias testCancelDelete: rowCancelDelete
        property alias testMetadata: recordingMetadata
        property alias testScheduled: detailsScheduled
        property alias testCaptured: detailsCaptured
        property alias testDuration: detailsDuration
        property alias testReason: detailsReason
        property alias testProgress: listeningProgress
        property alias testTitle: recordTitle""", 1))
        view.write_text(view.read_text().replace('        id: scheduleRow', '        id: scheduleRow\n        property alias testEdit: scheduleEditButton\n        property alias testTitle: scheduleTitle', 1))
        picker = plugin / "StationPicker.qml"
        picker.write_text(picker.read_text().replace('  property string value: ""', '  property alias testSearch: search\n  property alias testList: list\n  property alias testPopup: popup\n  property alias testEmpty: pickerEmpty\n  property alias testEmptyViewport: emptyViewport\n  property alias testAll: allFilter\n  property alias testFavorites: favoritesFilter\n  property alias testClear: clearSearch\n  property string value: ""', 1).replace('          id: stationRow', '          id: stationRow\n          property alias testTitle: stationTitle\n          property alias testFavorite: favoriteButton\n          property alias testResult: stationResult', 1))
        card = plugin / "StateCard.qml"
        card.write_text(card.read_text().replace('  property string title: ""', '  property alias testDiagnostics: diagnostics\n  property string title: ""', 1))
        service = plugin / "RadioService.qml"
        service.write_text(service.read_text().replace('  property int clients: 0', '  property alias testHelper: helper\n  property int clients: 0', 1))
        stations = json.loads((ROOT / "stations.json").read_text())
        # Returning live can only connect to this deliberately unused loopback address.
        for station in stations:
            station["streamUrl"] = "http://127.0.0.1:1/fixture"
        (plugin / "stations.json").write_text(json.dumps(stations))
        env = os.environ.copy()
        env.pop("QT_QPA_PLATFORMTHEME", None)
        env.update(XDG_RUNTIME_DIR=str(runtime), XDG_DATA_HOME=str(data), XDG_CONFIG_HOME=str(config),
                   QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software", QML_XHR_ALLOW_FILE_READ="1",
                   QML_IMPORT_PATH=str(imports), GOCACHE=env.get("GOCACHE", str(cache)), CGO_ENABLED="0",
                   PATH=str(bin_dir) + os.pathsep + env["PATH"], YAKKER_NOTIFICATION_LOG=str(base / "notifications.log"))
        subprocess.run(["go", "build", "-o", str(plugin / "yakker-controller"), "./cmd/yakker-controller"], cwd=ROOT, env=env, check=True)
        (bin_dir / "mpv").write_text('#!/bin/sh\nexec /usr/bin/mpv --ao=null "$@"\n')
        (bin_dir / "mpv").chmod(0o755)
        (bin_dir / "notify-send").write_text('#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ["YAKKER_NOTIFICATION_LOG"], "a") as output:\n    output.write(json.dumps(sys.argv[1:]) + "\\n")\n')
        (bin_dir / "notify-send").chmod(0o755)
        audio = media / "test-recording.opus"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=60", "-c:a", "libopus", "-b:a", "24k", "-y", str(audio)], check=True)
        now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        recording = {"id": "test-recording", "scheduleId": "fixture", "label": "Fixture", "stationId": "wbz-fm", "stationName": "Station", "plannedStart": "2026-01-01T00:00:00Z", "plannedEnd": "2026-01-01T00:01:00Z", "startedAt": "2026-01-01T00:00:00Z", "endedAt": "2026-01-01T00:01:00Z", "status": "complete", "reason": "", "bytes": audio.stat().st_size, "durationSeconds": 60, "folder": str(media), "filename": audio.name}
        state = {"version": 1, "revision": 1, "settings": {"folder": str(media), "storageCapBytes": 5368709120, "freeSpaceReserveBytes": 1073741824, "concurrency": 3}, "schedules": [], "recordings": [recording], "seen": {}, "ruleFrom": {}, "cursor": now}
        (data / "yakker").mkdir()
        (data / "yakker/recordings.json").write_text(json.dumps(state))
        # JSON string escaping is also correct for a QML string literal.
        qml = (SMOKE / ("compact.qml" if args.compact else "recordings.qml")).read_text().replace('"__OUTPUT__/"', json.dumps(str(output) + "/"))
        (base / "shell.qml").write_text(qml)
        run = subprocess.run(["quickshell", "-p", str(base / "shell.qml")], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120 if args.compact else 60)
        print(run.stdout)
        marker = "YAKKER_COMPACT_VIEWS" if args.compact else "YAKKER_FULL_RECORDINGS_REAL_CONTROLLER"
        if run.returncode or marker + "_PASS" not in run.stdout or marker + "_FAIL" in run.stdout:
            raise SystemExit("Native recordings UI smoke test failed")
        if args.compact:
            print("Compact audit screenshots:", output)
            return
        notices = [json.loads(line) for line in (base / "notifications.log").read_text().splitlines()]
        assert sum(args[-2] == "Recordings need attention" for args in notices) == 1, notices
        print("Notification delivery: unexpected helper exit reported once")
        print("Screenshots:", output)


if __name__ == "__main__":
    main()
