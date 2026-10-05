#!/usr/bin/env bash
# Only acquired local closure, mandatory trusted signatures, NO sync repositories.
set -euo pipefail
[[ $# == 1 ]]
work=$(/usr/bin/cygpath -u "$1")
[[ -f "$work/reports/compiler-packages-lock.json" ]]
export PATH=/usr/bin
config="$work/offline-pacman.conf"
printf '[options]\nArchitecture = auto\nSigLevel = Required\nLocalFileSigLevel = Required\n' > "$config"
mapfile -t packages < <(cut -d '|' -f3 "$work/pacman-plan.txt")
paths=()
for name in "${packages[@]}"; do
  [[ "$name" != */* && -f "$work/downloads/$name" && -f "$work/downloads/$name.sig" ]]
  paths+=("$work/downloads/$name")
done
# A missing dependency cannot be fetched from a newer remote database.
pacman -U --config "$config" --noconfirm "${paths[@]}" \
  > "$work/logs/pacman-install.txt" 2>&1
