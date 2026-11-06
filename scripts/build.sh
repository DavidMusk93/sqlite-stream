#!/usr/bin/env bash
set -euo pipefail
domain=$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")
tools=$(bash "$domain/scripts/bootstrap.sh")
zig=$(printf '%s\n' "$tools" | sed -n '1p')
sqlite=$(printf '%s\n' "$tools" | sed -n '2p')
zstd=$(printf '%s\n' "$tools" | sed -n '3p')
cache=$(dirname "$sqlite")
output=${SQLITE_STREAM_OUTPUT:-"$cache/release"}
[[ "$output" = /* ]]
export ZIG_GLOBAL_CACHE_DIR="$cache/zig-global"
action=${1:-native}
common=(--build-file "$domain/build.zig" "-Dsqlite-dir=$sqlite" "-Dzstd-dir=$zstd")
case "$action" in
  test)
    "$zig" build test "${common[@]}" --cache-dir "$cache/native-cache"
    "$zig" fmt --check "$domain/build.zig" "$domain/src"
    ;;
  native)
    "$zig" build "${common[@]}" -Doptimize=ReleaseSafe --cache-dir "$cache/native-cache" --prefix "$output/native"
    ;;
  release)
    for target in x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos; do
      "$zig" build "${common[@]}" "-Dtarget=$target" -Doptimize=ReleaseSafe \
        --cache-dir "$cache/$target-cache" --prefix "$output/$target"
      binary="$output/$target/bin/sqlite-stream"
      if command -v sha256sum >/dev/null; then digest=$(sha256sum "$binary" | awk '{print $1}')
      else digest=$(shasum -a 256 "$binary" | awk '{print $1}'); fi
      printf '%s  sqlite-stream\n' "$digest" > "$binary.sha256"
    done
    ;;
  *) echo "usage: bash scripts/build.sh [test|native|release]" >&2; exit 2 ;;
esac
