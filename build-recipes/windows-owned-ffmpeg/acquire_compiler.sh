#!/usr/bin/env bash
# Resolve into a frozen plan BEFORE installer execution; default mirror drift denied.
set -euo pipefail
[[ $# == 1 ]]
work=$(/usr/bin/cygpath -u "$1")
[[ -f "$work/owned.json" ]]
export PATH=/usr/bin
pacman-key --init
pacman-key --populate msys2
# These are this attempt-owned MSYS config files, never a user's installation.
printf 'Server = https://repo.msys2.org/msys/$arch\n' > /etc/pacman.d/mirrorlist.msys
printf 'Server = https://repo.msys2.org/mingw/$repo\n' > /etc/pacman.d/mirrorlist.mingw
pacman -Sy --noconfirm > "$work/logs/pacman-sync.txt" 2>&1
pacman -Sp --print-format '%n|%v|%f|%h|%l|%g' \
  'mingw-w64-x86_64-gcc=16.2.0-4' \
  'mingw-w64-x86_64-nasm=3.02-1' \
  'mingw-w64-x86_64-pkgconf=1~3.0.7-1' \
  mingw-w64-x86_64-zlib make \
  > "$work/pacman-plan.txt" 2> "$work/logs/pacman-plan.stderr"
cp /var/lib/pacman/sync/msys.db /var/lib/pacman/sync/mingw64.db "$work/reports/"
