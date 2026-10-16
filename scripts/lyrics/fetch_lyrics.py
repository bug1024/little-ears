#!/usr/bin/env python3
"""Fetch lyrics from LRCLIB (https://lrclib.net) for a local music directory.

Writes a sidecar .lrc next to each audio file, which is what the app's batch
import matches first (same directory + same file stem). Synced (timestamped)
lyrics are preferred; plain lyrics are written as a fallback, still readable as
untimed text. The `[ar:]/[ti:]/[al:]` header always comes from the audio file's
own tags, never from LRCLIB's crowd-sourced album field.

Typical run, then convert_hant.swift, then verify.py:

  python3 -I fetch_lyrics.py --root ~/Documents/musics/jay --dry-run
  python3 -I fetch_lyrics.py --root ~/Documents/musics/jay --overrides overrides.json
  swift convert_hant.swift ~/Documents/musics/jay .lyrics-hant-backup  # see README
  python3 -I verify.py ~/Documents/musics/jay

`-I` keeps Python from importing modules out of a music directory. Responses are
cached under ./cache so re-runs (and re-scoring) cost no extra requests. The
cache never stores error responses, so a re-run retries whatever failed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

API = "https://lrclib.net/api"
UA = "little-ears-lyrics-fetch/1.0 (personal music library)"
AUDIO_EXT = {".flac", ".mp3", ".m4a", ".aac", ".wav", ".ogg", ".opus", ".wma", ".ape"}
SLEEP = 0.25           # polite pacing between live API calls
DUR_TOLERANCE = 5.0    # seconds: accept a candidate within this of the file duration
# Characters that exist only in Traditional Chinese: only ever used to *prefer*
# a Simplified record, so the set need not be exhaustive. Actual conversion is
# convert_hant.swift's job (ICU), which deliberately keeps 妳.
TRADITIONAL = re.compile(r"[說們時間愛這麼樣為國學會個東風點樂聲無處來對開關門頭發現長還過應該話讓覺"
                         r"車記聽寫讀師願與淚彎閣絕膽連飄從憶妳繫髮幾難誰後溫體圓歲紅兒]")


# ---------------------------------------------------------------- HTTP layer
class Client:
    def __init__(self, cache_dir: str) -> None:
        self.cache_dir = cache_dir
        os.makedirs(cache_dir, exist_ok=True)
        self.live = 0

    def get(self, path: str, params: dict, retries: int = 5):
        """Return (status, payload). 404 -> (404, None). Payload is dict or list."""
        query = urllib.parse.urlencode(params)
        url = f"{API}/{path}?{query}"
        key = hashlib.sha256(url.encode()).hexdigest()[:24]
        cached = os.path.join(self.cache_dir, key + ".json")
        if os.path.exists(cached):
            with open(cached, encoding="utf-8") as fh:
                blob = json.load(fh)
            return blob["status"], blob["payload"]

        for attempt in range(retries):
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=25) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
                self.live += 1
                self._store(cached, 200, payload)
                time.sleep(SLEEP)
                return 200, payload
            except urllib.error.HTTPError as exc:
                if exc.code == 404:
                    self.live += 1
                    self._store(cached, 404, None)
                    time.sleep(SLEEP)
                    return 404, None
                if exc.code in (408, 425, 429, 500, 502, 503, 504) and attempt < retries - 1:
                    time.sleep(1.5 * (attempt + 1) ** 2)
                    continue
                self.live += 1
                return exc.code, None
            except Exception:  # noqa: BLE001 - network flake: retry
                if attempt < retries - 1:
                    time.sleep(1.5 * (attempt + 1) ** 2)
                    continue
                return 0, None
        return 0, None

    @staticmethod
    def _store(path: str, status: int, payload) -> None:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"status": status, "payload": payload}, fh, ensure_ascii=False)


# ------------------------------------------------------------ tag extraction
def probe(path: str) -> dict:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", path],
            capture_output=True, text=True, timeout=60, check=True,
        ).stdout
    except Exception:  # noqa: BLE001
        return {}
    fmt = json.loads(out).get("format", {})
    tags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}
    try:
        duration = float(fmt.get("duration") or 0.0)
    except (TypeError, ValueError):
        duration = 0.0
    return {
        "title": (tags.get("title") or "").strip(),
        "artist": (tags.get("artist") or tags.get("albumartist") or "").strip(),
        "album": (tags.get("album") or "").strip(),
        "duration": duration,
    }


BRACKET = re.compile(r"\s*[\(\（\[\【][^)\）\]\】]*[\)\）\]\】]\s*")


def title_candidates(title: str, stem: str) -> list[str]:
    """Titles to try, most specific first (dedup, order preserved)."""
    out: list[str] = []

    def add(value: str) -> None:
        value = value.strip(" -_")
        if value and value not in out:
            out.append(value)

    if title:
        add(title)
        add(BRACKET.sub(" ", title))
    # filename stem: "周杰伦 - 晴天" / "周杰伦-等你下课(with 杨瑞代)"
    tail = re.split(r"\s*[-–—]\s*", stem, maxsplit=1)
    if len(tail) == 2:
        add(BRACKET.sub(" ", tail[1]))
    add(BRACKET.sub(" ", stem))
    return [c for c in out if c]


def artist_candidates(artist: str, stem: str) -> list[str]:
    out: list[str] = []

    def add(value: str) -> None:
        value = value.strip()
        if value and value not in out:
            out.append(value)

    head = re.split(r"\s*[-–—]\s*", stem, maxsplit=1)
    if len(head) == 2:
        add(head[0])
    if artist:
        add(artist)
    # "周杰伦 袁咏琳" -> also try just the lead artist
    for value in list(out):
        first = value.split()[0] if value.split() else ""
        if first:
            add(first)
    return out


# --------------------------------------------------------------- matching
def is_monotonic(text: str) -> bool:
    """Timestamps in ascending order: some LRCLIB submissions append a stray
    duplicate block, which a player would then interleave with the real one."""
    times = []
    for row in text.split("\n"):
        for match in re.finditer(r"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]", row):
            times.append(int(match.group(1)) * 60 + float(match.group(2)))
    return all(b >= a for a, b in zip(times, times[1:]))


def rank(rec, want: dict, title: str):
    """Lexicographic rank for a candidate; None means it is not this song.

    Ordered by: has a time axis, duration bucket, Simplified-script preference,
    exact duration, title agreement, artist agreement. A tuple (rather than a
    weighted sum) keeps the priorities honest: a timed lyric is never traded
    away for a script difference.
    """
    if not isinstance(rec, dict):
        return None
    rec_dur = rec.get("duration") or 0.0
    diff = abs(rec_dur - want["duration"]) if (rec_dur and want["duration"]) else 999.0
    if diff > DUR_TOLERANCE:
        return None
    bucket = 0 if diff <= 1.0 else (1 if diff <= 2.5 else 2)
    text = rec.get("syncedLyrics") or rec.get("plainLyrics") or ""
    rec_title = (rec.get("trackName") or "").strip()
    return (
        0 if (rec.get("syncedLyrics") or "").strip() else 1,
        bucket,
        # Monotonicity outranks script: a stray duplicate block garbles playback
        # and cannot be repaired, while a Traditional record is converted after.
        0 if is_monotonic(text) else 1,
        len(set(TRADITIONAL.findall(text))),
        round(diff, 2),
        0 if rec_title == title else 1,
        0 if (want["artist"] and want["artist"] in (rec.get("artistName") or "")) else 1,
    )


def best_of(records, want, title):
    if not isinstance(records, list):
        records = [records] if records else []
    ranked = [(rank(r, want, title), r) for r in records]
    ranked = [pair for pair in ranked if pair[0] is not None]
    if not ranked:
        return None, None
    ranked.sort(key=lambda pair: pair[0])
    return ranked[0][1], ranked[0][0]


def has_lyrics(rec: dict | None) -> bool:
    """LRCLIB carries some records flagged instrumental that actually have text."""
    if not rec:
        return False
    return bool((rec.get("syncedLyrics") or "").strip() or (rec.get("plainLyrics") or "").strip())


def find_by_override(client: Client, override: dict):
    """Explicit per-file lookup for the rare song whose local version differs in
    length or credited artist from every LRCLIB record (user-confirmed cases)."""
    params = {k: v for k, v in override.items()
              if k in ("track_name", "artist_name", "album_name", "q") and v}
    # A free-text query is the widest net: prefer it when the override gives one.
    if override.get("q"):
        params = {"q": override["q"]}
    payload, status = None, None
    for attempt in range(5):
        status, payload = client.get("search", params)
        if status == 200 and isinstance(payload, list) and payload:
            break
        # This endpoint 503s under load: back off, then widen the query.
        time.sleep(1.5 * (attempt + 1))
        params = {"track_name": override.get("track_name", "")} if attempt == 2 and override.get("track_name") else params
        if attempt == 3 and override.get("q"):
            params = {"q": override["q"]}
    if status != 200 or not isinstance(payload, list) or not payload:
        return None, f"override:{status or 'empty'}", str(params.get("track_name", ""))
    title = params.get("track_name", "")
    if not override.get("ignore_duration"):
        ranked = [(rank(r, {"duration": 0, "artist": params.get("artist_name", ""), "album": ""}, title), r)
                  for r in payload]
        ranked = [pair for pair in ranked if pair[0] is not None]
        if ranked:
            ranked.sort(key=lambda pair: pair[0])
            return ranked[0][1], "override:ranked", title
    def pick(rec):
        text = rec.get("syncedLyrics") or rec.get("plainLyrics") or ""
        return (
            0 if (rec.get("syncedLyrics") or "").strip() else 1,
            0 if (rec.get("trackName") or "").strip() == title else 1,
            len(set(TRADITIONAL.findall(text))),
            -(len(text)),
        )
    best = min((r for r in payload if isinstance(r, dict)), key=pick)
    return best, "override:manual", title


def find_lyrics(client: Client, want: dict, titles: list[str], artists: list[str],
                override: dict | None = None):
    """Return (record, how, title_used). Prefers records that carry lyrics text.

    /api/search is the primary matcher: it answers reliably and returns whole
    records (synced + plain text), while /api/get is server-side flaky (503s on
    perfectly valid queries) and is only used as a fallback here.
    """
    if override:
        return find_by_override(client, override)

    fallback = None      # matched but empty (instrumental): keep, use only if nothing else
    saw_error = None

    # 1) search by track + artist, then track alone, then free text
    for title in titles:
        for params in (
            {"track_name": title, "artist_name": artists[0]} if artists else None,
            {"track_name": title},
            {"q": f"{title} {artists[0]}" if artists else title},
        ):
            if not params:
                continue
            status, payload = client.get("search", params)
            if status not in (200, 404):
                saw_error = status
                continue
            if status != 200:
                continue
            rec, _ = best_of(payload, want, title)
            if not rec:
                continue
            if has_lyrics(rec):
                return rec, f"search:{'+'.join(sorted(params))}", title
            fallback = fallback or rec

    # 2) exact lookup as a fallback
    for title in titles:
        for artist in artists[:2]:
            params = {"artist_name": artist, "track_name": title}
            if want["duration"]:
                params["duration"] = round(want["duration"], 1)
            status, payload = client.get("get", params, retries=2)
            if status in (200, 404):
                if status == 200 and isinstance(payload, dict) and rank(payload, want, title) is not None:
                    if has_lyrics(payload):
                        return payload, "get", title
                    fallback = fallback or payload
                continue
            saw_error = status
        if want["album"] and artists:
            status, payload = client.get("get", {
                "artist_name": artists[0],
                "track_name": title,
                "album_name": want["album"],
                "duration": round(want["duration"], 1),
            }, retries=2)
            if status == 200 and isinstance(payload, dict) and rank(payload, want, title) is not None:
                if has_lyrics(payload):
                    return payload, "get-album", title
                fallback = fallback or payload
            elif status not in (200, 404):
                saw_error = status

    if fallback:
        return fallback, "instrumental", titles[0] if titles else ""
    return None, f"error:{saw_error}" if saw_error else "no-match", titles[0] if titles else ""


META_LINE = re.compile(r"^\s*\[[a-zA-Z#]+:[^\]]*\]\s*$")


def file_header(want: dict) -> str:
    """Header from the file's own tags: LRCLIB album fields are crowd-sourced and
    frequently wrong (e.g. "Optional(\"魔杰座\")"), so they never label the file."""
    parts = []
    if want.get("artist"):
        parts.append(f"[ar:{want['artist']}]")
    if want.get("title"):
        parts.append(f"[ti:{want['title']}]")
    if want.get("album"):
        parts.append(f"[al:{want['album']}]")
    return "".join(p + "\n" for p in parts)


def strip_metadata(text: str) -> str:
    """Drop tag rows (which may also appear inside LRCLIB's own text)."""
    lines = [ln for ln in text.split("\n") if not META_LINE.match(ln)]
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines)


def compose_lrc(rec: dict, want: dict) -> tuple[str, str]:
    """Return (content, kind). Line endings are normalized: some LRCLIB text
    carries CRLF inside the string, which would survive the write."""
    header = file_header(want)
    synced = strip_metadata((rec.get("syncedLyrics") or "").replace("\r\n", "\n").replace("\r", "\n").strip())
    if synced:
        return header + synced + "\n", "synced"
    plain = strip_metadata((rec.get("plainLyrics") or "").replace("\r\n", "\n").replace("\r", "\n").strip())
    if plain:
        return f"{header}\n{plain}\n", "plain"
    return "", "instrumental"


# ------------------------------------------------------------------- driver
def walk(root: str) -> list[str]:
    found = []
    for base, _dirs, files in os.walk(root):
        for name in files:
            if os.path.splitext(name)[1].lower() in AUDIO_EXT:
                found.append(os.path.join(base, name))
    return sorted(found)


def process_one(client: Client, path: str, dry_run: bool, force: bool = False,
                overrides: dict | None = None, root: str = ""):
    """Return (kind, row, message). kind is one of the counts keys."""
    stem = os.path.splitext(os.path.basename(path))[0]
    lrc_path = os.path.splitext(path)[0] + ".lrc"
    rel = os.path.relpath(path, root) if root else os.path.basename(path)
    override = (overrides or {}).get(rel)
    want = probe(path)
    if not want:
        return "skipped", {"file": path, "status": "probe-failed"}, f"SKIP (no metadata) {os.path.basename(path)}"

    titles = title_candidates(want["title"], stem)
    artists = artist_candidates(want["artist"], stem)
    rec, how, used = find_lyrics(client, want, titles, artists, override)

    if not rec:
        row = {"file": path, "status": "missing", "how": how,
               "title": want["title"], "duration": want["duration"]}
        return "missing", row, f"MISS  {stem}  ({want['duration']:.0f}s)  [{how}]"

    content, kind = compose_lrc(rec, want)
    if not content:
        row = {"file": path, "status": "instrumental",
               "matched": f"{rec.get('artistName')} - {rec.get('trackName')}"}
        return "instrumental", row, f"INSTR {stem}"

    if os.path.exists(lrc_path) and not force:
        row = {"file": path, "status": "exists-kept", "how": how, "lrc": lrc_path}
        return "skipped", row, f"KEEP  {stem}.lrc already present"

    if not dry_run:
        with open(lrc_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)
    delta = abs((rec.get("duration") or 0) - want["duration"])
    text = rec.get("syncedLyrics") or rec.get("plainLyrics") or ""
    row = {
        "file": path, "status": kind, "how": how,
        "title_used": used,
        "matched": f"{rec.get('artistName')} - {rec.get('trackName')}",
        "album": rec.get("albumName"),
        "duration_delta": round(delta, 2),
        "traditional_chars": len(set(TRADITIONAL.findall(text))),
        "lrclib_id": rec.get("id"),
        "lrc": lrc_path,
    }
    return kind, row, (f"{kind.upper():6} {stem}  <- {rec.get('artistName')} - "
                       f"{rec.get('trackName')} ({rec.get('albumName')}) Δ{delta:.1f}s [{how}]")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--report", default="")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--force", action="store_true", help="re-evaluate and overwrite existing .lrc files")
    ap.add_argument("--overrides", default="", help="JSON file: relative path -> explicit search params")
    ap.add_argument("--cache", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache"))
    args = ap.parse_args()

    files = walk(args.root)
    overrides = json.load(open(args.overrides, encoding="utf-8")) if args.overrides else {}
    client = Client(args.cache)
    rows: list[dict] = []
    counts = {"synced": 0, "plain": 0, "instrumental": 0, "missing": 0, "skipped": 0}
    done = 0

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = {pool.submit(process_one, client, path, args.dry_run, args.force, overrides, args.root): path
               for path in files}
        for future in as_completed(futures):
            path = futures[future]
            try:
                kind, row, message = future.result()
            except Exception as exc:  # noqa: BLE001
                kind, row, message = "skipped", {"file": path, "status": f"error:{exc}"}, f"ERROR {path}: {exc}"
            counts[kind] += 1
            rows.append(row)
            done += 1
            print(f"[{done}/{len(files)}] {message}", flush=True)

    rows.sort(key=lambda r: r["file"])
    print("\n=== summary ===")
    for key, value in counts.items():
        print(f"{key:13} {value}")
    print(f"live API calls: {client.live}")
    if args.report:
        with open(args.report, "w", encoding="utf-8") as fh:
            json.dump({"root": args.root, "dry_run": args.dry_run, "counts": counts, "rows": rows},
                      fh, ensure_ascii=False, indent=2)
        print(f"report: {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())