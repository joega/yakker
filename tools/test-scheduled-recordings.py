#!/usr/bin/env python3
"""Opt-in live-station schedule/playback audit; never uses installed user data.

Requires ffmpeg, ffprobe and mpv. Copies a supplied controller into a private
bundle, uses isolated XDG data/runtime and silent mpv, and retains local audio
and JSON evidence in a NEW output directory. Explicit --stations contacts those
broadcasters, including independent longer reference connections.
"""
import argparse
import array
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import wave

ROOT = Path(__file__).resolve().parent.parent
UTC = dt.timezone.utc


def iso(value):
    return dt.datetime.fromtimestamp(value, UTC).isoformat()


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def minute_values(raw, count, minimum, maximum, label):
    values = list(map(int, raw.split(",")))
    if len(values) == 1:
        values *= count
    if len(values) != count or any(v < minimum or v > maximum for v in values):
        raise ValueError(f"{label}: provide one value or one per station, from {minimum} to {maximum}")
    return values


def schedule_windows(now, minutes, offsets, padding):
    base = (now+dt.timedelta(seconds=max(p[0] for p in padding)+15)).replace(second=0, microsecond=0)+dt.timedelta(minutes=1)
    return [(base+dt.timedelta(minutes=offset), base+dt.timedelta(minutes=offset+length))
            for length, offset in zip(minutes, offsets)]


def foreground_sample(state, station_id, player_pid):
    # The controller nests station identity; the widget exposes stationId separately.
    sample = {k:state.get(k) for k in ("state", "playerPid", "retry", "error")}
    sample["stationId"] = (state.get("station") or {}).get("id")
    if sample["state"] != "playing" or sample["stationId"] != station_id or sample["playerPid"] != player_pid or sample["error"] or sample["retry"]:
        raise RuntimeError("foreground listening was interrupted; inspect foreground samples and controller logs")
    return sample


def mpv_position(path):
    # Live-only UI position is intentionally zero. Read the actual decoder clock.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect(str(path))
        connection.sendall(b'{"command":["get_property","time-pos"],"request_id":1}\n')
        with connection.makefile("r") as messages:
            for line in messages:
                response = json.loads(line)
                if response.get("request_id") == 1:
                    value = response.get("data")
                    if response.get("error") == "success" and isinstance(value, (int, float)) and math.isfinite(value):
                        return value
                    break
    raise RuntimeError("foreground decoder clock is unavailable")


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def recover_reference_wav(source):
    """Finalize only received PCM frames; keep the forcibly stopped original."""
    target = source.with_name(source.stem+"-recovered.wav")
    frames, discarded = 0, 0
    with wave.open(str(source), "rb") as reader:
        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate(), reader.getcomptype()) != (1, 2, 16000, "NONE"):
            raise RuntimeError("forced-stop reference has an unexpected PCM format")
        with target.open("xb") as destination, wave.open(destination, "wb") as writer:
            writer.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            while pcm := reader.readframes(65536):
                tail = len(pcm) % 2
                discarded += tail
                if tail:
                    pcm = pcm[:-tail]
                writer.writeframesraw(pcm)
                frames += len(pcm)//2
    if not frames:
        raise RuntimeError("forced-stop reference has no complete PCM frames")
    return target, {"original":source.name,"recovered":target.name,"frames":frames,"discardedTailBytes":discarded}


def ffmpeg(*args):
    result = subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-nostdin", "-n", "-protocol_whitelist", "file,pipe", *map(str, args)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode or result.stderr.strip():
        raise RuntimeError("FFmpeg audio decode/conversion failed; inspect retained local files")
    return result.stdout


def envelope(path):
    """50 Hz log-RMS features from a 1 kHz mono decode, for content alignment."""
    pcm = array.array("f")
    pcm.frombytes(ffmpeg("-i", path, "-ac", 1, "-ar", 1000, "-f", "f32le", "pipe:1"))
    if sys.byteorder != "little":
        pcm.byteswap()
    return [math.log1p(100 * math.sqrt(sum(x*x for x in pcm[i:i+20])/20))
            for i in range(0, len(pcm)-19, 20)]


def find_match(reference, template):
    """Normalized correlation; confidence is reported, never presumed."""
    n = len(template)
    if n < 100 or len(reference) < n:
        return None
    mean = sum(template)/n
    centered = [x-mean for x in template]
    norm = sum(x*x for x in centered)
    if norm < 1e-8:
        return None
    sums, squares = [0.0], [0.0]
    for x in reference:
        sums.append(sums[-1]+x)
        squares.append(squares[-1]+x*x)
    best = (-1.0, 0)
    scores = []
    for offset in range(len(reference)-n+1):
        total = sums[offset+n]-sums[offset]
        variance = max(0, squares[offset+n]-squares[offset]-total*total/n)
        if variance < 1e-8:
            continue
        dot = sum(x*reference[offset+i] for i, x in enumerate(centered))
        score = dot/math.sqrt(norm*variance)
        scores.append((score, offset))
        if score > best[0]:
            best = (score, offset)
    runner_up = max((score for score, offset in scores if abs(offset-best[1])>50), default=-1)
    return {"correlation": best[0], "referenceSecond": best[1]/50, "ambiguityMargin":best[0]-runner_up}


def delivery_bounds(progress, wall_time):
    before = [p for p in progress if p["wallTime"] <= wall_time]
    after = [p for p in progress if p["wallTime"] >= wall_time]
    if not before or not after:
        return None
    return [before[-1]["mediaSecond"], after[0]["mediaSecond"]]


def confident(match):
    return bool(match and match["correlation"] >= .85 and match["ambiguityMargin"] >= .05)


def match_delivery_boundary(saved, reference, bounds):
    if not bounds:
        return {"confirmed": False, "reason": "reference progress does not bracket this boundary"}
    wider = None
    for context in (4, 2):
        lo = max(0, math.floor((bounds[0]-context)*50))
        hi = min(len(reference), math.ceil((bounds[1]+context)*50))
        if hi < bounds[1]*50 or lo > bounds[0]*50:
            return {"confirmed": False, "reason": "reference audio does not span this boundary"}
        match = find_match(saved, reference[lo:hi])
        result = {"confirmed": confident(match), "match": match, "referenceIntervalSeconds": [lo/50, hi/50],
                  "contextSeconds": context}
        if wider:
            result["widerContextMatch"] = wider
        if result["confirmed"]:
            result["savedDeliveryBounds"] = [match["referenceSecond"]+value-lo/50 for value in bounds]
            return result
        if wider is None:
            wider = result
    return result


def compare_boundaries(recording, reference, progress, start, end):
    saved, longer = envelope(recording), envelope(reference)
    length, inset = 400, 25  # Eight seconds, half a second away from each edge.
    if len(saved) < length+2*inset:
        return {"available": False, "reason": "too little audio for independent edge matching"}
    head = find_match(longer, saved[inset:inset+length])
    tail_at = len(saved)-inset-length
    tail = find_match(longer, saved[tail_at:tail_at+length])
    result = {"head": head, "tail": tail, "startDeliveryBounds": delivery_bounds(progress, start),
              "endDeliveryBounds": delivery_bounds(progress, end)}
    result["fileEdgesMatched"] = False
    inferred_coverage = None
    if confident(head) and confident(tail):
        first = head["referenceSecond"]-inset/50
        last = tail["referenceSecond"]+(len(saved)-tail_at)/50
        drift = (last-first)-len(saved)/50
        result.update(firstRetainedReferenceSecond=first, lastRetainedReferenceSecond=last,
                      headTailAlignmentDifference=drift, fileEdgesMatched=abs(drift)<=.2)
        a, b = result["startDeliveryBounds"], result["endDeliveryBounds"]
        if result["fileEdgesMatched"] and a and b:
            inferred_coverage = first <= a[0] and last >= b[1]
    # Match the requested boundaries themselves. Extra post-roll can contain
    # different ads/content without invalidating the original show ending.
    result["programStartMatch"] = match_delivery_boundary(saved, longer, result["startDeliveryBounds"])
    result["programEndMatch"] = match_delivery_boundary(saved, longer, result["endDeliveryBounds"])
    available = result["programStartMatch"]["confirmed"] and result["programEndMatch"]["confirmed"]
    coverage = True if available else False if inferred_coverage is False else None
    result.update(available=available, coversReferenceDeliveryBoundaries=coverage)
    if not available:
        result["reason"] = "scheduled boundary content did not confidently match; independent ads/content may differ"
    if not result["fileEdgesMatched"]:
        result["edgeNote"] = "physical file edges did not both align confidently; review retained head/tail clips separately"
    return result


def ogg_eos(path):
    data, pos, flags = path.read_bytes(), 0, 0
    while pos < len(data):
        if pos+27 > len(data) or data[pos:pos+4] != b"OggS":
            return False
        count = data[pos+26]
        if pos+27+count > len(data):
            return False
        size = 27+count+sum(data[pos+27:pos+27+count])
        if pos+size > len(data):
            return False
        flags = data[pos+5]
        pos += size
    return bool(flags & 4)


class Controller:
    def __init__(self, executable, env, output, generation):
        self.serial, self.latest, self.messages = 0, {}, queue.Queue()
        self.log = (output/f"controller-{generation}.jsonl").open("w")
        self.stderr = (output/f"controller-{generation}.log").open("w")
        self.process = subprocess.Popen([str(executable)], env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr, text=True, bufsize=1)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.wait(lambda s: s.get("recordings", {}).get("revision", 0) > 0)
        if not self.latest["recordings"]["available"]:
            raise RuntimeError(self.latest["recordings"]["error"])

    def read(self):
        for line in self.process.stdout:
            self.log.write(line)
            self.log.flush()
            try:
                state = json.loads(line)
                self.latest = state
                self.messages.put(state)
            except json.JSONDecodeError:
                pass

    def wait(self, predicate, timeout=15):
        deadline = time.monotonic()+timeout
        while True:
            if self.latest.get("serial", 0) >= self.serial and predicate(self.latest):
                return self.latest
            if self.process.poll() is not None:
                raise RuntimeError("isolated controller exited unexpectedly")
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                raise RuntimeError("controller check timed out: " + json.dumps({k:self.latest.get(k) for k in ("state", "error", "position", "recordingError", "playbackProgressError")}))
            try:
                state = self.messages.get(timeout=min(.5, remaining))
                if state.get("serial", 0) >= self.serial and predicate(state):
                    return state
            except queue.Empty:
                pass

    def command(self, action, **fields):
        self.serial += 1
        serial = self.serial
        self.process.stdin.write(json.dumps(dict(action=action, serial=serial, **fields))+"\n")
        self.process.stdin.flush()
        state = self.wait(lambda s:s.get("serial") == serial)
        if state.get("error") or state.get("playbackProgressError"):
            raise RuntimeError(state.get("error") or state.get("playbackProgressError"))
        return state

    def mutate(self, action, **fields):
        fields["revision"] = self.latest["recordings"]["revision"]
        state = self.command(action, **fields)
        if state.get("recordingMutationSerial") != self.serial or not state.get("recordingMutationOK"):
            raise RuntimeError(state.get("recordingError") or "recording mutation failed")
        return state

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write(json.dumps({"action":"quit","serial":self.serial+1})+"\n")
                self.process.stdin.flush()
                self.process.wait(timeout=20)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=2)
        self.log.close()
        self.stderr.close()


class Reference:
    def __init__(self, station, output):
        self.path = output/(station["id"]+"-reference.wav")
        self.progress = []
        self.log = (output/(station["id"]+"-reference.log")).open("w")
        self.process = subprocess.Popen(["ffmpeg", "-v", "error", "-nostdin", "-n", "-rw_timeout", "15000000",
                                        "-i", station["streamUrl"], "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000",
                                        "-c:a", "pcm_s16le", "-flush_packets", "1", "-progress", "pipe:1", "-stats_period", "0.2",
                                        str(self.path)], stdout=subprocess.PIPE, stderr=self.log, text=True)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.killed = False
        self.recovery = None

    def read(self):
        for line in self.process.stdout:
            if line.startswith("out_time_us="):
                try:
                    self.progress.append({"wallTime":time.time(),"mediaSecond":int(line.split("=",1)[1])/1e6})
                except ValueError:
                    pass

    def close(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.killed = True
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=2)
        self.log.close()
        original = self.path
        if self.killed:
            self.path, self.recovery = recover_reference_wav(original)
        write_json(original.with_suffix(".progress.json"), {"forcedStop":self.killed,"points":self.progress,"wavRecovery":self.recovery})


def row(state, recording_id):
    return next(r for r in state["recordings"]["recordings"] if r["id"] == recording_id)


def save_resume(controller, item):
    rid, target = item["id"], min(20, item["durationSeconds"]/2)
    controller.command("playRecording", id=rid, fromStart=True)
    controller.wait(lambda s:s.get("state")=="playing" and s.get("recordingId")==rid and s.get("position",0)>.4)
    paused = controller.command("pause")
    paused = controller.wait(lambda s:s.get("paused") is True and s.get("state")=="paused")
    if paused.get("temporaryBuffer") or paused.get("dvr"):
        raise RuntimeError("recorded-file pause enabled live buffering")
    controller.command("seekRecording", value=target)
    controller.wait(lambda s:s.get("paused") is True and abs(s.get("position",0)-target)<.5)
    stopped = controller.command("stop")
    saved = row(stopped, rid)["resumePosition"]
    if abs(saved-target) > .5:
        raise RuntimeError(f"saved resume position {saved} differs from paused seek {target}")
    return {"pauseAndSeek":True,"stopped":stopped["state"]=="stopped","savedPosition":saved}


def check_resume(controller, item, saved):
    rid = item["id"]
    stored = row(controller.latest, rid)["resumePosition"]
    if abs(stored-saved) > .1:
        raise RuntimeError("controller restart lost the saved position")
    controller.command("playRecording", id=rid)
    resumed = controller.wait(lambda s:s.get("state")=="playing" and s.get("recordingId")==rid and s.get("position",0)>=saved-.5)
    if resumed["position"] > saved+2:
        raise RuntimeError("resume skipped beyond the saved position")
    controller.command("pause")
    paused = controller.wait(lambda s:s.get("paused") is True)
    position = paused["position"]
    controller.command("play")
    controller.wait(lambda s:s.get("state")=="playing" and s.get("position",0)>position+.3)
    controller.command("seekRecording", value=item["durationSeconds"]-1.5)
    ended = controller.wait(lambda s:s.get("state")=="stopped" and not s.get("wanted"), timeout=10)
    if row(ended, rid)["resumePosition"] != 0:
        raise RuntimeError("EOF did not clear resume position")
    return {"persistedAcrossControllerRestart":True,"resumedPosition":resumed["position"],
            "pauseResume":True,"tailPlaybackAndEOF":True,"eofClearedPosition":True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller", type=Path, default=ROOT/"yakker-controller")
    parser.add_argument("--stations", required=True, help="one to three comma-separated bundled station IDs")
    parser.add_argument("--padding", default="10:15,20:10,30:20", help="pre:post seconds per station; defaults vary by station")
    parser.add_argument("--minutes", default="1", help="program minutes: one value or one per station, from 1 to 30")
    parser.add_argument("--offsets", default="0", help="start offsets in minutes: one value or one per station, from 0 to 10")
    parser.add_argument("--listen-station", help="different bundled station to play silently during scheduled captures")
    parser.add_argument("--output", type=Path, required=True, help="new private evidence directory")
    args = parser.parse_args()
    os.umask(0o077)
    ids = args.stations.split(",")
    catalogue = {s["id"]:s for s in json.loads((ROOT/"stations.json").read_text())}
    if len(ids) > 3 or len(set(ids)) != len(ids) or any(i not in catalogue for i in ids):
        parser.error("choose one to three distinct bundled station IDs")
    if args.listen_station and (args.listen_station not in catalogue or args.listen_station in ids):
        parser.error("--listen-station must be a different bundled station")
    try:
        padding = [tuple(map(int, p.split(":"))) for p in args.padding.split(",")]
        minutes = minute_values(args.minutes, len(ids), 1, 30, "--minutes")
        offsets = minute_values(args.offsets, len(ids), 0, 10, "--offsets")
    except ValueError as exc:
        parser.error(str(exc))
    if len(padding) < len(ids) or any(len(p)!=2 or any(x<0 or x>60 for x in p) for p in padding):
        parser.error("provide pre:post padding from 0 to 60 seconds for each station")
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir(mode=0o700)
    bundle = output/"bundle"
    bundle.mkdir()
    executable = bundle/"yakker-controller"
    shutil.copy2(args.controller, executable)
    stations = [catalogue[i] for i in ids]
    write_json(bundle/"stations.json", stations+([catalogue[args.listen_station]] if args.listen_station else []))
    mpv = shutil.which("mpv")
    if not mpv:
        raise SystemExit("mpv is required")
    bindir = output/"bin"
    bindir.mkdir()
    wrapper = bindir/"mpv"
    wrapper.write_text("#!/bin/sh\nexec "+shlex.quote(mpv)+' --ao=null --load-scripts=no "$@"\n')
    wrapper.chmod(0o700)
    for name in ("data", "config", "media"):
        (output/name).mkdir()
    report = {"controllerSha256":hashlib.sha256(executable.read_bytes()).hexdigest(),"stations":[],"failures":[],"completed":False}
    controller, references = None, []
    with tempfile.TemporaryDirectory(prefix="yk-scheduled-") as runtime:
        env = dict(os.environ, XDG_RUNTIME_DIR=runtime, XDG_DATA_HOME=str(output/"data"),
                   XDG_CONFIG_HOME=str(output/"config"), PATH=str(bindir)+os.pathsep+os.environ["PATH"])
        try:
            controller = Controller(executable, env, output, 1)
            settings = dict(controller.latest["recordings"]["settings"], folder=str(output/"media"))
            controller.mutate("recordingSettings", settings=settings)
            now = dt.datetime.now(UTC)
            windows = schedule_windows(now, minutes, offsets, padding[:len(ids)])
            report.update(programStart=min(w[0] for w in windows).isoformat(),programEnd=max(w[1] for w in windows).isoformat())
            for station, (pre, post), (start, end) in zip(stations, padding, windows):
                references.append(Reference(station, output))
                schedule = {"stationId":station["id"],"kind":"once","date":start.strftime("%Y-%m-%d"),
                            "startTime":start.strftime("%H:%M"),"endTime":end.strftime("%H:%M"),"timezone":"UTC",
                            "label":"Scheduled audit · "+station["name"],"enabled":True,"preRollSeconds":pre,"postRollSeconds":post}
                controller.mutate("upsertSchedule", schedule=schedule)
                report["stations"].append({"id":station["id"],"name":station["name"],"preRollSeconds":pre,"postRollSeconds":post,
                                           "programStart":start.isoformat(),"programEnd":end.isoformat()})
                print(f"Scheduled {station['name']}: {start.isoformat()}–{end.isoformat()}, {pre}s before, {post}s after", flush=True)
            if args.listen_station:
                controller.command("configure", stationId=args.listen_station)
                controller.command("play")
                playing = controller.wait(lambda s:s.get("state")=="playing" and (s.get("station") or {}).get("id")==args.listen_station, timeout=35)
                report["foreground"] = {"stationId":args.listen_station,"playerPid":playing["playerPid"],"samples":[]}
                print("Playing separate foreground station with null audio: "+catalogue[args.listen_station]["name"], flush=True)
            write_json(output/"report.json", report)
            last_capture_end = max(end.timestamp()+post for (_, end), (_, post) in zip(windows, padding))
            deadline = last_capture_end+25
            previous = None
            max_active = 0
            next_sample = 0
            next_heartbeat = time.monotonic()+30
            while True:
                snapshot = controller.latest["recordings"]
                active = snapshot["activeCount"]
                max_active = max(max_active, active)
                if active != previous:
                    print(f"Active scheduled captures: {active}", flush=True)
                    previous = active
                if snapshot.get("error"):
                    raise RuntimeError(snapshot["error"])
                if args.listen_station and time.monotonic() >= next_sample:
                    state = controller.command("status")
                    sample = foreground_sample(state, args.listen_station, report["foreground"]["playerPid"])
                    sample["position"] = mpv_position(Path(runtime)/"io.github.joega.yakker/mpv.sock")
                    sample.update(wallTime=time.time(), activeCount=state["recordings"]["activeCount"])
                    report["foreground"]["samples"].append(sample)
                    next_sample = time.monotonic()+1
                if time.monotonic() >= next_heartbeat:
                    print(f"Recording audit running: {active} captures, {max(0, deadline-time.time()):.0f}s until final deadline", flush=True)
                    write_json(output/"report.json", report)
                    next_heartbeat = time.monotonic()+30
                if len(snapshot["recordings"]) >= len(ids) and not active and time.time() >= last_capture_end:
                    break
                if time.time() > deadline:
                    raise RuntimeError("scheduled captures did not finish by their bounded deadline")
                time.sleep(.2)
            report["maximumConcurrentCaptures"] = max_active
            if args.listen_station:
                samples = report["foreground"]["samples"]
                report["foreground"]["maximumConcurrentCaptures"] = max(s["activeCount"] for s in samples)
                report["foreground"]["positionAdvancedSeconds"] = samples[-1]["position"]-samples[0]["position"]
                if report["foreground"]["positionAdvancedSeconds"] < 1:
                    raise RuntimeError("foreground playback did not advance")
                controller.command("stop")
            recordings = controller.latest["recordings"]["recordings"]
            for result in report["stations"]:
                items = [r for r in recordings if r["stationId"]==result["id"]]
                result["recordings"] = items
                if len(items)!=1 or not items[0]["playable"]:
                    report["failures"].append(result["id"]+": expected one playable capture")
                    continue
                item = items[0]
                if item["status"] != "complete":
                    report["failures"].append(result["id"]+": capture ended "+item["status"]+"; "+item.get("reason", ""))
                path = Path(item["folder"])/item["filename"]
                ffmpeg("-i", path, "-f", "null", "-")
                result["fullDecode"] = True
                result["finalizedOggEOS"] = ogg_eos(path)
                result["startDelaySeconds"] = timestamp(item["startedAt"])-timestamp(item["captureStart"])
                result["endDelaySeconds"] = timestamp(item["endedAt"])-timestamp(item["captureEnd"])
                result["processSurroundedProgram"] = timestamp(item["startedAt"])<timestamp(result["programStart"]) and timestamp(item["endedAt"])>=timestamp(result["programEnd"])
                if not result["finalizedOggEOS"] or not result["processSurroundedProgram"]:
                    report["failures"].append(result["id"]+": capture boundary or finalization check failed")
                for label, position in (("head",0),("tail",max(0,item["durationSeconds"]-8))):
                    ffmpeg("-ss", position, "-i", path, "-t", 8, "-ac", 1, "-ar", 16000, output/(result["id"]+"-"+label+".wav"))
                result["playback"] = save_resume(controller, item)
                print(result["id"]+": decode, head/tail extraction, pause, seek and saved position passed", flush=True)
            while time.time() < last_capture_end+8:
                time.sleep(.2)
            for reference in references:
                reference.close()
            controller.close()
            controller = Controller(executable, env, output, 2)
            for result, reference in zip(report["stations"], references):
                if "playback" not in result:
                    continue
                item = result["recordings"][0]
                result["playback"].update(check_resume(controller, item, result["playback"]["savedPosition"]))
                result["boundaries"] = compare_boundaries(Path(item["folder"])/item["filename"], reference.path, reference.progress,
                                                          timestamp(result["programStart"]), timestamp(result["programEnd"]))
                result["referenceWavRecovery"] = reference.recovery
                if result["boundaries"].get("coversReferenceDeliveryBoundaries") is False:
                    report["failures"].append(result["id"]+": saved audio did not cover independent reference delivery boundaries")
                print(result["id"]+": persisted resume, pause/resume and ending playback passed; reference match "+str(result["boundaries"]["available"]), flush=True)
            report["completed"] = True
        except Exception as exc:
            report["failures"].append(str(exc))
        finally:
            if controller:
                controller.close()
            for reference in references:
                if not reference.log.closed:
                    reference.close()
            if not report["completed"] and not report["failures"]:
                report["failures"].append("audit interrupted before completion")
            write_json(output/"report.json", report)
    if report["failures"]:
        raise SystemExit("Audit failed: "+"; ".join(report["failures"]))
    print("Scheduled recordings audit passed. Evidence: "+str(output), flush=True)


if __name__ == "__main__":
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    main()
