#!/usr/bin/env python3
"""Exercise real recording recovery against a loopback time-coded audio source.

No broadcaster connections, installed data changes, or audible playback. Requires
a built controller, FFmpeg/libopus and mpv. All evidence stays in a NEW directory.
"""
import argparse
import array
import concurrent.futures
import datetime as dt
import hashlib
import http.server
import importlib.util
import json
import math
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("scheduled_audit", ROOT/"tools/test-scheduled-recordings.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
RATE = 16000
CASES = ("drop-once", "stall-once", "retry-limit", "graceful-restart", "forced-restart", "empty-start", "manual-stop", "expired-restart")


class Fixture:
    def __init__(self, origin):
        self.origin, self.lock, self.requests, self.stop = origin, threading.Lock(), {}, threading.Event()

    def handler(self):
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                name = self.path.lstrip("/")
                with fixture.lock:
                    requests = fixture.requests.setdefault(name, [])
                    request = {"attempt":len(requests)+1, "connectedAt":time.time(), "samples":0}
                    requests.append(request)
                if name == "empty-start" and request["attempt"] <= 2:
                    self.send_error(503, "controlled temporary outage")
                    return
                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
                self.end_headers()
                header = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 0x7fffffff, b"WAVE", b"fmt ", 16, 1, 1,
                                     RATE, RATE*2, 2, 16, b"data", 0x7fffffdb)
                start_sample = int((time.time()-fixture.origin)*RATE)
                request["firstSourceSecond"] = start_sample/RATE
                drop = 8 if name == "drop-once" and request["attempt"] == 1 else 4 if name == "retry-limit" else None
                sent, next_tick = 0, time.monotonic()
                try:
                    self.wfile.write(header)
                    self.wfile.flush()
                    while not fixture.stop.is_set():
                        if name == "stall-once" and request["attempt"] == 1 and sent >= 8*RATE:
                            request["stalledAt"] = time.time()
                            while not fixture.stop.is_set():
                                readable, _, _ = select.select([self.connection], [], [], .2)
                                if readable and not self.connection.recv(1, socket.MSG_PEEK):
                                    return
                            return
                        if drop and sent >= drop*RATE:
                            request["droppedAt"] = time.time()
                            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                            self.close_connection = True
                            return
                        next_tick += .02
                        if fixture.stop.wait(max(0, next_tick-time.monotonic())):
                            return
                        values = []
                        for i in range(RATE//50):
                            seconds = (start_sample+sent+i)/RATE
                            values.append(int(14000*math.sin(2*math.pi*(300*seconds+15*seconds*seconds))))
                        self.wfile.write(struct.pack("<"+"h"*len(values), *values))
                        self.wfile.flush()
                        sent += len(values)
                        request["samples"] = sent
                except (BrokenPipeError, ConnectionResetError, OSError):
                    pass
                finally:
                    request["disconnectedAt"] = time.time()
                    request["lastSourceSecond"] = (start_sample+sent)/RATE

        return Handler


def wait_for(predicate, timeout=20):
    until = time.monotonic()+timeout
    while time.monotonic() < until:
        result = predicate()
        if result:
            return result
        time.sleep(.04)
    raise RuntimeError("recovery condition timed out")


def children(pid):
    direct = set()
    for task in Path("/proc", str(pid), "task").glob("*/children"):
        try:
            direct.update(map(int, task.read_text().split()))
        except OSError:
            pass
    return direct.union(*(children(child) for child in direct)) if direct else direct


def alive(pid):
    try:
        return Path("/proc", str(pid), "stat").read_text().rsplit(") ", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def audio_positions(path):
    pcm = array.array("h")
    pcm.frombytes(audit.ffmpeg("-i", path, "-ac", 1, "-ar", RATE, "-f", "s16le", "pipe:1"))
    if sys.byteorder != "little":
        pcm.byteswap()

    def position(tail):
        a, b = (len(pcm)-RATE//4, len(pcm)-RATE//25) if tail else (RATE//25, RATE//4)
        crossings = [i-pcm[i]/(pcm[i]-pcm[i-1]) for i in range(a+1, b) if pcm[i-1] <= 0 < pcm[i]]
        if len(crossings) < 3:
            raise RuntimeError("time-coded audio could not be measured")
        first, last = crossings[0], crossings[-1]
        frequency = (len(crossings)-1)*RATE/(last-first)
        center = (first+last)/2/RATE
        return (frequency-300)/30 + (len(pcm)/RATE-center if tail else -center)

    return {"decodedSeconds":len(pcm)/RATE, "firstSourceSecond":position(False), "lastSourceSecond":position(True)}


class Scenario:
    def __init__(self, name, root, runtime, controller, url, start, end, fixture):
        self.name, self.fixture, self.start, self.end = name, fixture, start, end
        self.root = root/name
        self.root.mkdir()
        for folder in ("bundle", "bin", "data", "config", "media"):
            (self.root/folder).mkdir()
        self.executable = self.root/"bundle/yakker-controller"
        shutil.copy2(controller, self.executable)
        stations = [{"id":name,"name":"Controlled "+name,"subtitle":"Loopback fixture","streamUrl":url+"/"+name},
                    {"id":name+"-other","name":"Future edited station","subtitle":"Not used by active capture","streamUrl":url+"/unexpected-"+name}]
        audit.write_json(self.root/"bundle/stations.json", stations)
        wrapper = self.root/"bin/mpv"
        wrapper.write_text("#!/bin/sh\nexec "+shlex.quote(shutil.which("mpv"))+' --ao=null --load-scripts=no "$@"\n')
        wrapper.chmod(0o700)
        runtime = runtime/name
        runtime.mkdir(mode=0o700)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_DATA_HOME=str(self.root/"data"),
                        XDG_CONFIG_HOME=str(self.root/"config"), PATH=str(self.root/"bin")+os.pathsep+os.environ["PATH"])
        self.generation, self.controller = 0, None
        self.result = {"case":name,"events":[],"failures":[]}
        self.restart()
        settings = dict(self.controller.latest["recordings"]["settings"], folder=str(self.root/"media"))
        self.controller.mutate("recordingSettings", settings=settings)
        schedule = {"stationId":name,"label":"Original "+name,"kind":"once","date":start.strftime("%Y-%m-%d"),
                    "startTime":start.strftime("%H:%M"),"endTime":end.strftime("%H:%M"),"timezone":"UTC",
                    "enabled":True,"preRollSeconds":5,"postRollSeconds":5}
        self.controller.mutate("upsertSchedule", schedule=schedule)

    def restart(self):
        self.generation += 1
        self.controller = audit.Controller(self.executable, self.env, self.root, self.generation)
        self.result["events"].append({"kind":"controller-start","at":time.time(),"pid":self.controller.process.pid})

    def disk(self):
        return json.loads((self.root/"data/yakker/recordings.json").read_text())

    def check(self, condition, message):
        if not condition:
            self.result["failures"].append(message)

    def stop_controller(self, forced=False):
        pids = children(self.controller.process.pid)
        event = {"kind":"controller-kill" if forced else "controller-quit","at":time.time(),"children":sorted(pids)}
        self.result["events"].append(event)
        if forced:
            self.controller.process.kill()
            self.controller.process.wait(timeout=5)
        self.controller.close()
        wait_for(lambda:not any(alive(pid) for pid in pids), timeout=5)
        event["childrenExited"] = True
        return event

    def run(self):
        try:
            timeout = max(15, self.start.timestamp()-time.time()+15)
            self.controller.wait(lambda s:s["recordings"]["activeCount"]==1, timeout=timeout)
            initial = self.disk()["recordings"][0]
            if self.name == "retry-limit":
                pending = wait_for(lambda:next((r for r in self.disk()["recordings"] if r.get("resumeAfter")), None))
                self.result["persistedBackoff"] = pending["resumeAfter"]
                self.stop_controller()
                self.restart()
                wait_for(lambda:any(r.get("failures")==3 for r in self.disk()["recordings"]))
                self.stop_controller()
                self.restart()
            elif self.name in ("graceful-restart", "forced-restart", "manual-stop", "expired-restart"):
                wait_for(lambda:time.time() >= audit.timestamp(initial["startedAt"])+12)
                wait_for(lambda:(Path(initial["folder"])/initial["filename"]).stat().st_size > 512)
                if self.name == "graceful-restart":
                    # Future edits must not replace the retained source/window.
                    edited = dict(self.controller.latest["recordings"]["schedules"][0])
                    edited.update(stationId=self.name+"-other",label="Edited future show",enabled=False,
                                  endTime=(self.end+dt.timedelta(minutes=1)).strftime("%H:%M"),preRollSeconds=30,postRollSeconds=60)
                    self.controller.mutate("upsertSchedule", schedule=edited, refreshStation=True)
                if self.name == "manual-stop":
                    self.controller.mutate("stopRecording", id=initial["id"])
                    self.controller.wait(lambda s:s["recordings"]["activeCount"]==0)
                event = self.stop_controller(forced=self.name in ("forced-restart", "expired-restart"))
                disk_before = self.disk()["recordings"][0]
                path = Path(disk_before["folder"])/disk_before["filename"]
                self.result["originalHashAfterStop"] = hashlib.sha256(path.read_bytes()).hexdigest()
                if self.name == "expired-restart":
                    wait_for(lambda:time.time()>self.end.timestamp()+7, timeout=80)
                else:
                    time.sleep(2)
                self.restart()
                recovered = self.controller.latest["recordings"]["recordings"][0]
                self.result["recoveredOriginal"] = recovered
                if self.name in ("forced-restart", "expired-restart"):
                    self.check(not recovered["endedAt"] or audit.timestamp(recovered["endedAt"]) <= event["at"]+.2,
                               "crash recovery invented a capture end at restart time")
            wait_for(lambda:time.time()>self.end.timestamp()+7, timeout=110)
            self.controller.wait(lambda s:s["recordings"]["activeCount"]==0)
            wait_for(lambda:not any(r.get("resume") or r.get("resumeAfter") for r in self.disk()["recordings"]), timeout=5)
            self.controller.command("status")
            disk = self.disk()
            rows = disk["recordings"]
            expected = {"drop-once":2,"stall-once":2,"retry-limit":3,"graceful-restart":2,"forced-restart":2,
                        "empty-start":3,"manual-stop":1,"expired-restart":1}[self.name]
            self.check(len(rows)==expected, f"expected {expected} segments, got {len(rows)}")
            self.check(len(disk["seen"])==1, "occurrence identity duplicated or lost")
            self.check(not any(r.get("resume") or r.get("resumeAfter") for r in rows), "expired window retained retry intent")
            frozen = [initial.get(k) for k in ("scheduleId","stationId","plannedStart","plannedEnd","captureStart","captureEnd","streamUrl","label")]
            previous_end = None
            for i, item in enumerate(rows):
                self.check([item.get(k) for k in ("scheduleId","stationId","plannedStart","plannedEnd","captureStart","captureEnd","streamUrl","label")]==frozen,
                           "segment changed the original source or padded interval")
                self.check(item.get("parentId", "")==("" if i==0 else rows[i-1]["id"]), "broken remainder parent link")
                self.check(item["status"] in ("partial","error"), "interrupted segment was falsely marked complete")
                if item["durationSeconds"] <= 0:
                    self.check(item["status"]=="error", "empty output was not marked error")
                    self.check(not audit.row(self.controller.latest,item["id"])["playable"], "empty output was offered for playback")
                    continue
                path = Path(item["folder"])/item["filename"]
                measured = audio_positions(path)
                measured.update(id=item["id"],status=item["status"],finalizedOggEOS=audit.ogg_eos(path))
                if i > 0 or self.name not in ("forced-restart", "expired-restart"):
                    self.check(measured["finalizedOggEOS"], "drained segment lacks a finalized Ogg page")
                if previous_end is not None:
                    measured["gapFromPreviousSeconds"] = measured["firstSourceSecond"]-previous_end
                previous_end = measured["lastSourceSecond"]
                self.result.setdefault("audio", []).append(measured)
                if i==0 and "originalHashAfterStop" in self.result:
                    self.check(hashlib.sha256(path.read_bytes()).hexdigest()==self.result["originalHashAfterStop"], "recovery overwrote original audio")
                self.controller.command("playRecording", id=item["id"], fromStart=True)
                self.controller.wait(lambda s:s.get("state")=="playing" and s.get("recordingId")==item["id"])
                self.controller.command("pause")
                self.controller.wait(lambda s:s.get("paused") is True)
                self.controller.command("stop")
                measured["controllerPlaybackPassed"] = True
            with self.fixture.lock:
                requests = list(self.fixture.requests.get(self.name, []))
                unexpected = self.fixture.requests.get("unexpected-"+self.name, [])
            self.check(len(requests)==expected, f"expected {expected} source connections, got {len(requests)}")
            self.check(not unexpected, "remainder used edited future station")
            if self.name == "retry-limit":
                self.check(rows[-1].get("failures")==3 and "retry limit" in rows[-1]["reason"], "retry budget/explanation lost across restart")
                self.check(requests[1]["connectedAt"] >= audit.timestamp(self.result["persistedBackoff"])-.05, "restart ignored persisted backoff")
                for previous, following in zip(rows, requests[1:]):
                    delay = following["connectedAt"]-audit.timestamp(previous["endedAt"])
                    self.check(delay >= previous.get("failures",0)-.1, "retry ignored increasing delay")
            if self.name == "manual-stop":
                self.check(rows[0]["reason"]=="stopped by user", "explicit stop reason lost")
            if self.name == "stall-once" and len(requests) >= 2:
                delay = requests[1]["connectedAt"]-requests[0]["stalledAt"]
                self.result["stallToRetrySeconds"] = delay
                self.check(13 <= delay <= 23, "stalled connection did not recover within the input-timeout/retry bound")
            self.result.update(recordings=rows, sourceRequests=requests)
        except Exception as exc:
            self.result["failures"].append(str(exc))
        finally:
            self.controller.close()
            audit.write_json(self.root/"report.json", self.result)
        print(self.name+": "+("PASS" if not self.result["failures"] else "FAIL "+"; ".join(self.result["failures"])), flush=True)
        return self.result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller", type=Path, default=ROOT/"yakker-controller")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cases", default=",".join(CASES), help="comma-separated subset of recovery cases")
    args = parser.parse_args()
    for program in ("ffmpeg", "ffprobe", "mpv"):
        if not shutil.which(program):
            parser.error(program+" is required")
    names = args.cases.split(",")
    if len(names) != len(set(names)) or any(name not in CASES for name in names):
        parser.error("choose distinct known cases: "+", ".join(CASES))
    os.umask(0o077)
    root = args.output.resolve()
    root.parent.mkdir(parents=True, exist_ok=True)
    root.mkdir(mode=0o700)
    now = dt.datetime.now(dt.timezone.utc)
    start = (now+dt.timedelta(seconds=15)).replace(second=0,microsecond=0)+dt.timedelta(minutes=1)
    end = start+dt.timedelta(minutes=1)
    fixture = Fixture(start.timestamp()-5)
    server = http.server.ThreadingHTTPServer(("127.0.0.1",0), fixture.handler())
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:"+str(server.server_port)
    report = {"programStart":start.isoformat(),"programEnd":end.isoformat(),
              "controllerSha256":hashlib.sha256(args.controller.read_bytes()).hexdigest(),"cases":[]}
    scenarios = []
    try:
        with tempfile.TemporaryDirectory(prefix="yk-recover-") as runtime:
            for name in names:
                scenarios.append(Scenario(name,root,Path(runtime),args.controller,url,start,end,fixture))
            print("Recovery audit: "+start.isoformat()+" to "+end.isoformat()+", with 5s padding each side",flush=True)
            with concurrent.futures.ThreadPoolExecutor(max_workers=len(scenarios)) as pool:
                report["cases"] = list(pool.map(lambda scenario:scenario.run(),scenarios))
    finally:
        fixture.stop.set()
        for scenario in scenarios:
            if scenario.controller and not scenario.controller.log.closed:
                scenario.controller.close()
        server.shutdown()
        server.server_close()
        audit.write_json(root/"report.json",report)
    if len(report["cases"])!=len(names) or any(case["failures"] for case in report["cases"]):
        raise SystemExit("Recording recovery audit failed; inspect "+str(root/"report.json"))
    print("All recovery cases passed: "+str(root/"report.json"),flush=True)


if __name__ == "__main__":
    main()
