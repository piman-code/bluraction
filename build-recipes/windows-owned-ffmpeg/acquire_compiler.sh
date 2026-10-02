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
# Preserve exact DB and actual runtime identity BEFORE any plan can crash.
cp /var/lib/pacman/sync/msys.db /var/lib/pacman/sync/mingw64.db "$work/reports/"
sha256sum "$work/reports/msys.db" "$work/reports/mingw64.db" \
  /usr/bin/pacman.exe /usr/bin/msys-2.0.dll > "$work/reports/pacman-runtime-sha256.txt"
pacman --version > "$work/reports/pacman-version.txt"
pacman -Q pacman msys2-runtime > "$work/reports/pacman-packages.txt"
targets=(
  'mingw-w64-x86_64-gcc=16.2.0-4'
  'mingw-w64-x86_64-nasm=3.02-1'
  'mingw-w64-x86_64-pkgconf=1~3.0.7-1'
  mingw-w64-x86_64-zlib make
)
# %g is nullable in the captured mingw64 DB and crashes this pacman build.
# Five nonnullable fields only; package_lock cross-checks the copied DB and
# obtains every mandatory signature before the existing offline PGP installer.
pacman -Sp --debug --print-format '%n|%v|%f|%h|%l' "${targets[@]}" \
  > "$work/pacman-plan.txt" 2> "$work/logs/pacman-plan.stderr"
