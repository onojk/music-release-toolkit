# Music Release Toolkit

A tiny, portable Bash helper that prepares audio tracks for digital distribution (DistroKid, SUNO, etc.).  
It **verifies files are unique**, **renames them in order**, and **writes a playlist**—so you can upload without headaches.

---

## Why this exists

Uploading an album often stalls on simple stuff: duplicate files, messy filenames, out-of-order tracks.  
This tool cleans that up in seconds so you can stay in the creative zone.

---

## What it does

- ✅ **Duplicate check (MD5)**: Detects byte-for-byte identical audio files before you submit.
- 🔢 **Sequential rename**: Converts files to `Number01.wav`, `Number02.wav`, … (customizable).
- 📝 **Playlist generation**: Writes a clean `playlist.m3u` in track order.
- 💾 **Backups**: Copies originals to `old/` (safety net).
- 🖥 **Portable**: Works on Linux and macOS (uses `openssl md5`, or `md5sum`, or `md5`—whichever is available).
- 🧪 **Dry-run mode**: See exactly what will happen before any changes.
- 🧰 **Flags**: `--max`, `--prefix`, `--ext`, `--backup-dir`, `--dry-run`, `--force`.

---

## Quick start (2 commands)

```bash
chmod +x scripts/rename_unique_wavs.sh
./scripts/rename_unique_wavs.sh --dry-run   # preview, no changes

If the preview looks good:

./scripts/rename_unique_wavs.sh

Prerequisites

    Bash (default on macOS/Linux)

    One of:

        openssl (usually preinstalled)

        or md5sum (GNU coreutils)

        or md5 (macOS)

    No other dependencies required.

    Note (macOS): If md5sum is missing, that’s fine—macOS has md5 and openssl.
    Note (Linux): If openssl is missing, md5sum is almost always present.

Typical workflow

    Export your tracks to a folder (e.g., MyAlbum/).

    Open a terminal and cd into that folder.

    Run a dry run:

/path/to/scripts/rename_unique_wavs.sh --dry-run

If no duplicates are reported, run it for real:

    /path/to/scripts/rename_unique_wavs.sh

    Upload the resulting Number01.wav … NumberNN.wav to DistroKid/SUNO.

    Keep old/ as your untouched originals and playlist.m3u for reference.

Command options
Option	What it does	Default
--max=N	Rename at most N files (still scans all for duplicates)	20
--prefix=NAME	Output prefix (NAME01.wav, NAME02.wav, …)	Number
--ext=EXT	File extension to process (case-insensitive)	wav
--backup-dir=DIR	Where originals are copied	old
--dry-run	Print actions without changing anything	off
--force	Continue even if duplicates are found	off
-h, --help	Show usage	—
Examples

Standard album (up to 20 tracks):

./scripts/rename_unique_wavs.sh

Custom prefix & 30 tracks:

./scripts/rename_unique_wavs.sh --prefix=Track --max=30

Work with FLAC instead of WAV:

./scripts/rename_unique_wavs.sh --ext=flac

Proceed even with duplicates (not recommended):

./scripts/rename_unique_wavs.sh --force

Preview everything first:

./scripts/rename_unique_wavs.sh --dry-run

What duplicate detection means

The script computes an MD5 hash of each file’s bytes.

    If two files have the same MD5, they’re exactly the same audio data (and likely the same file).

    You’ll see groups like:

    Duplicate group (MD5: <hash>):
      - Track A.wav
      - Track A (copy).wav

    Fix by removing/adjusting duplicates and re-running.

    Or override with --force if you really intend to keep them.

    MD5 is used here as a fast “are these files identical?” check (not for cryptography).

Safety & reversibility

    Originals are copied to old/ before any rename.

    Already-correctly-named files like Number07.wav are skipped.

    If you change your mind, your originals are in old/.

Troubleshooting

*“No .wav files found.”

    You’re not in the right folder, or the extension is different.

    Try: ls to confirm files; or run with --ext=FLAC/MP3 as needed.

“Permission denied” when running the script

chmod +x scripts/rename_unique_wavs.sh

“md5sum/openssl/md5 not found”

    macOS: use md5 (preinstalled) or install OpenSSL via Homebrew if you want: brew install openssl

    Linux: md5sum is part of coreutils (usually installed). If not: sudo apt install coreutils (Debian/Ubuntu).

Playlist is empty

    The playlist only lists files that already match the target scheme (PrefixNN.ext).

    After the first successful rename, run again if you changed the prefix or extension.

FAQ

Q: Does this alter audio quality/metadata?
A: No—only filenames are changed. The audio bytes are untouched.

Q: Can I continue numbering from an existing set?
A: Current behavior starts at 01 and skips files already named like PrefixNN.ext.
If you want an “auto-continue numbering” mode, open an issue or PR—we’ll add it.

Q: Will this work for MP3/FLAC/AIFF?
A: Yes—use --ext=mp3 (or flac, aiff, etc.). MD5 works on any file type.

Q: What if my filenames have spaces or parentheses?
A: Fully supported. The script handles them safely.
Publishing checklist (quick)

    Files renamed and ordered (Number01.wav, Number02.wav, …).

    No duplicates reported.

    Listen spot-check after renaming (just in case).

    Prepare artwork & metadata (title, artist, ISRC/UPC if needed).

    Upload to your distributor (DistroKid/SUNO/etc.).

    Tip: Keep playlist.m3u as your “canonical order” reference across platforms.

Contributing

    Issues and pull requests are welcome!

    Ideas: “continue numbering” mode, CSV track-title import, cover-art checker, loudness tips, GitHub Actions demo.

License

MIT License © Jonathan Kendall
