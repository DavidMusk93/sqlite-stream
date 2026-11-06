#!/usr/bin/env bash
# Compiler and C sources are pinned; nothing is installed globally.
set -euo pipefail
case "$(uname -s)" in
  Darwin) os=macos; default_cache="${HOME}/Library/Caches/sqlite-stream" ;;
  Linux) os=linux; default_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/sqlite-stream" ;;
  *) echo "Unsupported OS" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=aarch64 ;;
  x86_64|amd64) arch=x86_64 ;;
  *) echo "Unsupported architecture" >&2; exit 2 ;;
esac
cache=${SQLITE_STREAM_CACHE:-$default_cache}
[[ "$cache" = /* ]]
mkdir -p "$cache"
sha() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
fetch() {
  local url=$1 file=$2 digest=$3
  if [[ ! -f "$file" || "$(sha "$file")" != "$digest" ]]; then
    curl -fsSL --retry 2 "$url" -o "$file.download"
    [[ "$(sha "$file.download")" == "$digest" ]]
    mv "$file.download" "$file"
  fi
}
case "$os-$arch" in
  macos-aarch64) digest=75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d ;;
  macos-x86_64) digest=9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7 ;;
  linux-aarch64) digest=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795 ;;
  linux-x86_64) digest=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a ;;
esac
package="zig-$arch-$os-0.17.1"
if [[ ! -x "$cache/$package/zig" ]]; then
  fetch "https://ziglang.org/download/0.17.1/$package.tar.xz" "$cache/$package.tar.xz" "$digest"
  tar -xJf "$cache/$package.tar.xz" -C "$cache"
  printf '%s\n' "$digest" > "$cache/$package/.archive-sha256"
fi
[[ "$(cat "$cache/$package/.archive-sha256")" == "$digest" ]]
[[ "$("$cache/$package/zig" version)" == 0.17.1 ]]
if [[ ! -f "$cache/sqlite-amalgamation-3540100/sqlite3.c" ]]; then
  fetch https://sqlite.org/2026/sqlite-amalgamation-3540100.zip "$cache/sqlite-3540100.zip" 0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
  unzip -q "$cache/sqlite-3540100.zip" -d "$cache"
fi
[[ "$(sha "$cache/sqlite-amalgamation-3540100/sqlite3.c")" == 0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52 ]]
[[ "$(sha "$cache/sqlite-amalgamation-3540100/sqlite3.h")" == d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c ]]
# This source archive contains upstream Zstandard C, not a Rust build dependency.
crate="zstd-sys-2.1.2+zstd.1.5.7"
fetch "https://static.crates.io/crates/zstd-sys/$crate.crate" "$cache/$crate.crate" 481ada9c543b2323cbb7bbdbb5249177fbf0188ed959ed2c15e4b22421c84ed3
# Re-extract verified C source on each bootstrap, preventing stale edited caches.
tar -xzf "$cache/$crate.crate" -C "$cache"
printf '%s\n' "$cache/$package/zig" "$cache/sqlite-amalgamation-3540100" "$cache/$crate/zstd/lib"
