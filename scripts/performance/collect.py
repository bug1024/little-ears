#!/usr/bin/env python3
"""Read native per-process counters and opt-in runtime instrumentation into JSONL.

Phase labels come from SESSION/phase.txt. Never changes app state or reads lyrics.
"""
import argparse
import csv
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--session", type=Path, required=True)
parser.add_argument("--pid", type=int, required=True)
parser.add_argument("--sampler", type=Path, required=True)
args = parser.parse_args()
args.session.mkdir(parents=True, exist_ok=True)
process = subprocess.Popen([str(args.sampler.resolve()), str(args.pid)], stdout=subprocess.PIPE, text=True)
previous = None
last_phase = None
phase_start = 0
try:
    with (args.session / "samples.jsonl").open("a", encoding="utf-8") as output:
        for raw in csv.DictReader(process.stdout):
            row = {key: float(value) if key == "wall_s" else int(value) for key, value in raw.items()}
            now = row["wall_s"]
            phase_file = args.session / "phase.txt"
            phase = phase_file.read_text().strip() if phase_file.exists() else "unclassified"
            if phase != last_phase:
                last_phase = phase; phase_start = now
            row.update(phase=phase, phase_elapsed_s=now - phase_start)
            runtime_file = args.session / "runtime.json"
            try:
                row["runtime"] = json.loads(runtime_file.read_text())
                row["runtime_age_s"] = now - runtime_file.stat().st_mtime
            except (OSError, ValueError):
                row["runtime"] = {}
            if previous:
                dt = now - previous["wall_s"]
                if dt > 0:
                    row["cpu_percent"] = ((row["user_ns"] + row["system_ns"]) - (previous["user_ns"] + previous["system_ns"])) / (dt * 1e7)
                    for metric in ("interrupt_wakeups", "package_idle_wakeups", "read_bytes", "write_bytes", "pageins"):
                        row[metric + "_per_s"] = (row[metric] - previous[metric]) / dt
                    row["kernel_energy_watts_counter"] = (row["kernel_energy_nj"] - previous["kernel_energy_nj"]) / (dt * 1e9)
            output.write(json.dumps(row, ensure_ascii=False) + "\n"); output.flush()
            previous = row
except KeyboardInterrupt:
    pass
finally:
    process.terminate()
    process.wait()
