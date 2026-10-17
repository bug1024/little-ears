#!/usr/bin/env python3
"""Summarize steady-state samples; CPU 100% means one fully occupied core."""
import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('session', type=Path)
p.add_argument('--warmup', type=float, default=10)
a = p.parse_args()
groups = defaultdict(list)
raw_groups = defaultdict(list)
for line in (a.session / 'samples.jsonl').read_text().splitlines():
    x = json.loads(line)
    raw_groups[x['phase']].append(x)
    runtime = x.get('runtime', {})
    if x['phase'] == 'idle_library' and (runtime.get('page') != 'library' or runtime.get('playing')):
        continue
    if x['phase'] == 'flac_library_playing' and (runtime.get('page') != 'library' or not runtime.get('playing')):
        continue
    if x['phase_elapsed_s'] >= a.warmup and 'cpu_percent' in x and x.get('runtime_age_s', 999) < 3:
        groups[x['phase']].append(x)
def percentile(values, q):
    v = sorted(values)
    return v[int((len(v) - 1) * q)] if v else 0
results = []
for phase, rows in groups.items():
    if phase.startswith(('transition_', 'diagnostic_')):
        continue
    first, last = rows[0], rows[-1]
    dt = last['wall_s'] - first['wall_s']
    cpu = [r['cpu_percent'] for r in rows]
    memory = [r['footprint_bytes'] / 2**20 for r in rows]
    gpu_a = first['runtime'].get('gpu', {})
    gpu_b = last['runtime'].get('gpu', {})
    frames = gpu_b.get('completed_frames', 0) - gpu_a.get('completed_frames', 0)
    gpu_dt = last['runtime']['uptime'] - first['runtime']['uptime']
    gpu_s = gpu_b.get('gpu_seconds', 0) - gpu_a.get('gpu_seconds', 0)
    result = dict(phase=phase, samples=len(rows), seconds=round(dt, 1),
        raw_samples=len(raw_groups[phase]), stale_snapshots=sum(r.get('runtime_age_s', 999) >= 3 for r in raw_groups[phase]),
        cpu_mean=round(statistics.mean(cpu), 2), cpu_median=round(statistics.median(cpu), 2),
        cpu_p95=round(percentile(cpu, .95), 2), cpu_max=round(max(cpu), 2),
        footprint_mean_mib=round(statistics.mean(memory), 1), footprint_peak_mib=round(max(memory), 1),
        footprint_start_mib=round(memory[0], 1), footprint_end_mib=round(memory[-1], 1),
        interrupt_wakeups_s=round(statistics.mean(r.get('interrupt_wakeups_per_s', 0) for r in rows), 1),
        package_wakeups_s=round(statistics.mean(r.get('package_idle_wakeups_per_s', 0) for r in rows), 1),
        disk_read_kib_s=round(statistics.mean(r.get('read_bytes_per_s', 0) for r in rows) / 1024, 1),
        disk_write_kib_s=round(statistics.mean(r.get('write_bytes_per_s', 0) for r in rows) / 1024, 1),
        kernel_energy_mean_w=round(statistics.mean(r.get('kernel_energy_watts_counter', r.get('cpu_energy_watts_counter', 0)) for r in rows), 4),
        metal_fps=round(frames / gpu_dt, 2) if gpu_dt > 0 else 0,
        metal_gpu_ms_per_frame=round(gpu_s * 1000 / frames, 3) if frames else 0,
        metal_gpu_busy_ms_s=round(gpu_s * 1000 / gpu_dt, 2) if gpu_dt > 0 else 0,
        main_loop_gap_ms_max=round(max(r['runtime'].get('main_loop_gap_ms_max', 0) for r in rows), 1),
        thermal_states=sorted(set(r['runtime'].get('thermal_state', -1) for r in rows)),
        runtime_errors=sorted(set(r['runtime'].get('error', '') for r in rows) - {''}),
        end_state={k:last['runtime'].get(k) for k in ['page','playing','format','immersive','aquarium_running','aquarium_fish','aquarium_jellies','aquarium_power_saving','drawable_width','drawable_height','app_hidden','window_miniaturized','window_visible']})
    results.append(result)
(a.session / 'summary.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
for x in results:
    print(f"{x['phase']:<30} n={x['samples']:4} CPU={x['cpu_mean']:6.2f}% p95={x['cpu_p95']:6.2f}% mem={x['footprint_mean_mib']:6.1f}/{x['footprint_peak_mib']:6.1f}MiB GPU={x['metal_fps']:5.1f}fps {x['metal_gpu_ms_per_frame']:5.2f}ms Ecounter={x['kernel_energy_mean_w']:.4f}W")
