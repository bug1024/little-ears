#!/usr/bin/env python3
"""Verify the sidecar .lrc files written next to the music library.

Simulates the player's parser rules (LyricDocument.parse): metadata rows are
ignored for .lrc, timestamps must be well formed, and untimed text is legal.
"""
import os
import re
import sys

ROOT = sys.argv[1]
AUDIO = {".flac", ".mp3", ".m4a", ".aac", ".wav", ".ogg", ".opus", ".ape"}
TAG = re.compile(r"\[(\d{1,3}:\d{2}(?::\d{2})?(?:\.\d{1,3})?)\]")
META = re.compile(r"^\s*\[[a-zA-Z#]+:[^\]]*\]\s*$")

problems = []
stats = {"synced": 0, "plain": 0, "covered": 0}
missing = []


def duration_of(path):
    import subprocess
    try:
        out = subprocess.run(["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
                              "-of", "csv=p=0", path], capture_output=True, text=True, timeout=60).stdout
        return float(out.strip() or 0)
    except Exception:
        return 0.0


audio = []
for base, _dirs, files in os.walk(ROOT):
    if os.sep + ".lyrics-hant-backup" in base:
        continue
    for name in files:
        if os.path.splitext(name)[1].lower() in AUDIO:
            audio.append(os.path.join(base, name))

for path in sorted(audio):
    lrc = os.path.splitext(path)[0] + ".lrc"
    name = os.path.relpath(path, ROOT)
    if not os.path.exists(lrc):
        missing.append(name)
        continue
    raw = open(lrc, "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append(f"{name}: UTF-8 BOM")
    if b"\r\n" in raw:
        problems.append(f"{name}: CRLF line endings")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        problems.append(f"{name}: not UTF-8 ({exc})")
        continue

    times, content = [], []
    for row in text.replace("\r\n", "\n").split("\n"):
        if META.match(row):
            continue
        if row.strip():
            content.append(row)
        for match in TAG.finditer(row):
            pieces = match.group(1).split(":")
            try:
                nums = [float(p) for p in pieces]
            except ValueError:
                problems.append(f"{name}: bad timestamp {match.group(1)}")
                continue
            if len(nums) == 2:
                times.append(nums[0] * 60 + nums[1])
            elif len(nums) == 3:
                times.append(nums[0] * 3600 + nums[1] * 60 + nums[2])

    if not content:
        problems.append(f"{name}: no lyric text at all")
        continue
    stats["covered"] += 1
    if times:
        stats["synced"] += 1
        if times != sorted(times):
            problems.append(f"{name}: timestamps not ascending")
        dur = duration_of(path)
        if dur and times[-1] > dur + 30:
            problems.append(f"{name}: last timestamp {times[-1]:.1f}s beyond duration {dur:.1f}s")
        if times[0] < 0:
            problems.append(f"{name}: negative timestamp")
    else:
        stats["plain"] += 1

print(f"audio files       {len(audio)}")
print(f"with lyrics       {stats['covered']}   (timed {stats['synced']}, untimed {stats['plain']})")
print(f"without lyrics    {len(missing)}")
for name in missing:
    print(f"    - {name}")
print(f"problems          {len(problems)}")
for problem in problems[:25]:
    print(f"    ! {problem}")