#!/bin/sh
set -eu
cd "$(dirname "$0")"

REV=55c79c0e9029989c1901cce2862b30d00c00c37e
BASE=https://raw.githubusercontent.com/rkk-2s/bad-apple/$REV

mkdir -p src
for f in BadApple.mp4 bad-apple-audio.mp3; do
	[ -f "src/$f" ] || curl -fL# -o "src/$f" "$BASE/$f"
done

sha256sum -c <<EOF
79020e3030c48a1de929dcd8824b281dbd541649c1e8872ce4838d3e6f1a5189  src/BadApple.mp4
d3243fabeeff4e44e7820a8bd454e9545cdc070ed6987ef50f1a9cd7533305f8  src/bad-apple-audio.mp3
EOF

python3 gen_frames.py
