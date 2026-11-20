#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

output="${1:-build/test-audio}"
mkdir -p "$output"
labels=(MP3 AAC ALAC FLAC)
codecs=(libmp3lame aac alac flac)
extensions=(mp3 m4a m4a flac)
for index in "${!labels[@]}"; do
  label="${labels[$index]}"
  ffmpeg -hide_banner -loglevel error -n -f lavfi -i "sine=frequency=$((440 + 70 * index)):duration=12" \
    -c:a "${codecs[$index]}" -metadata "title=Orbit ${label}" -metadata 'artist=Twelve Fixtures' \
    -metadata 'album=Orbit' -metadata 'genre=Electronic' -metadata "track=$((index + 1))" \
    "$output/Orbit-$label.${extensions[$index]}"
done
printf '%s\n' "$output"
