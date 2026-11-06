# Dependency licenses

## Distributed executables

sqlite-stream is MIT licensed. Its executables statically include SQLite
(public domain), Zstandard under its BSD license, and Zig standard/runtime
code under the MIT license. Linux musl executables also include musl.

Upstream notices accompany every portable archive:

- [Zstandard BSD license](licenses/Zstandard.txt)
- [Zig MIT license](licenses/Zig.txt)
- [musl copyright and license](licenses/musl.txt)

SQLite's [public-domain declaration](https://sqlite.org/copyright.html)
applies to the upstream amalgamation. macOS executables use the operating
system's dynamically linked system library.

## Build inputs

Compiler and source versions and hashes are pinned in `scripts/bootstrap.sh`.
The Zstandard source download is a crate archive containing upstream C;
sqlite-stream does not build or require Rust.
When updating those inputs, review and refresh their upstream notices.
