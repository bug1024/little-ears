# Lyrics fetch

Fills in missing sidecar `.lrc` files for a local music library from
[LRCLIB](https://lrclib.net). This is a maintainer tool for preparing a library
before importing it into the app; the app itself never touches the network.

## Pipeline

```sh
python3 -I fetch_lyrics.py --root ~/Documents/musics/jay --dry-run   # preview matches
python3 -I fetch_lyrics.py --root ~/Documents/musics/jay             # write .lrc files
swift convert_hant.swift ~/Documents/musics/jay .lyrics-hant-backup  # Traditional -> Simplified
python3 -I verify.py ~/Documents/musics/jay                          # check every file parses
```

`-I` keeps Python from importing modules out of a music directory. Responses are
cached under `cache/` (git ignored), so re-runs and re-scoring cost no requests.

## What the files look like

One `.lrc` per song, next to the audio file and sharing its stem — the match the
app's batch import prefers (same directory, same file name). Two files of the
same song (`x.flac` and `x.mp3`) share one lyric file. `[ar:]/[ti:]/[al:]` come
from the audio file's own tags, never from LRCLIB's crowd-sourced album field.

## Rules the matcher follows

Candidates are ranked as a lexicographic tuple rather than a weighted sum, so the
priorities cannot trade against each other:

1. **has a time axis** — a synced lyric is never traded away for anything below
2. duration bucket, then **timestamps ascending** — LRCLIB submissions sometimes
   append a stray duplicate block, which a player would interleave with the real
   one; a Traditional record is preferable to that, because script is fixable
   afterwards and duplicates are not
3. **Simplified over Traditional** characters, then closest duration, then title
   and artist agreement

Anything further than 5s from the file's duration is rejected outright. `/api/get`
is only a fallback: it returns 503s for perfectly valid queries, while
`/api/search` is reliable. Note that `track_name` indexing has gaps — a song can
be missing there yet present via `q=` full-text search, so an empty result array
(not a 503) is the only reliable "LRCLIB does not have this song".

## Manual cases

`overrides.json` maps a library-relative path to explicit search parameters for
songs whose local version differs from every LRCLIB record in length or credited
artist (e.g. a cover that LRCLIB only carries under the original artist). Each
entry should say why it is there.

## Converting script

`convert_hant.swift` uses the ICU `Hant-Hans` transform that ships with macOS,
one process for the whole tree. It touches Han characters only, so timestamps and
tags survive unchanged, and it skips the directory passed as its second argument —
always pass the backup directory so rollback copies stay Traditional.

ICU deliberately keeps `妳`; that is not a missed conversion. It also cannot help
songs whose every LRCLIB candidate is Traditional, which is common for Chinese
lyrics since much of the corpus is Taiwanese-submitted.