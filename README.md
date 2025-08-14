# Music Release Toolkit

A tiny Bash helper for prepping audio releases (DistroKid, SUNO, etc.).

## Features
- Verifies audio uniqueness by MD5
- Renames tracks to `Number01.wav`, `Number02.wav`, etc.
- Creates `playlist.m3u` in version-sorted order
- Works on Linux and macOS

## Quick start
\`\`\`bash
chmod +x scripts/rename_unique_wavs.sh
./scripts/rename_unique_wavs.sh --dry-run
\`\`\`
