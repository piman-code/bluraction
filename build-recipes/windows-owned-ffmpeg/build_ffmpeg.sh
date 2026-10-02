#!/usr/bin/env bash
# QA draft: must run only inside the newly acquired MSYS tree.
set -euo pipefail
if [[ $# != 1 ]]; then exit 64; fi
work=$(/usr/bin/cygpath -u "$1")
case "$work" in *$'\n'*|*$'\r'*) exit 64;; esac
[[ -f "$work/owned.json" && -d "$work/ffmpeg-source/ffmpeg-9.0.2" ]]
export PATH=/mingw64/bin:/usr/bin
export PKG_CONFIG_PATH=/mingw64/lib/pkgconfig
mkdir "$work/ffmpeg-build"
cd "$work/ffmpeg-build"
"$work/ffmpeg-source/ffmpeg-9.0.2/configure" \
  --prefix="$work/prefix" --target-os=mingw32 --arch=x86_64 \
  --cc=gcc --cxx=g++ --enable-shared --disable-static \
  --enable-gpl --enable-version3 --disable-nonfree --disable-autodetect \
  --enable-mediafoundation --enable-w32threads --enable-zlib \
  --disable-network --disable-doc \
  --extra-cflags=-I/mingw64/include --extra-ldflags=-L/mingw64/lib \
  > "$work/logs/ffmpeg-configure.stdout" 2> "$work/logs/ffmpeg-configure.stderr"
make -j2 > "$work/logs/ffmpeg-build.stdout" 2> "$work/logs/ffmpeg-build.stderr"
make install > "$work/logs/ffmpeg-install.stdout" 2> "$work/logs/ffmpeg-install.stderr"
cp config.h config_components.h ffbuild/config.mak "$work/reports/"
cp "$work/ffmpeg-source/ffmpeg-9.0.2/LICENSE.md" "$work/reports/ffmpeg-LICENSE.md"
cp "$work/ffmpeg-source/ffmpeg-9.0.2/COPYING.GPLv3" "$work/reports/ffmpeg-COPYING.GPLv3"
gcc --version > "$work/reports/gcc-version.txt"
gcc -dumpmachine > "$work/reports/gcc-target.txt"
nasm -v > "$work/reports/nasm-version.txt"
pacman -Q > "$work/reports/installed-msys-packages.txt"
# First owned core build: external dav1d/vpx/SVT/x264/x265/HEIF/Qt are
# not silently declared supported. This is not the application's final codec set.
