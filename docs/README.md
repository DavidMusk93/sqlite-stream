# Documentation

## Contracts

- [Archive format](format.md): encoding, deterministic traversal and validation.
- [Security and resources](security.md): trust boundaries and failure behavior.

## Validation

Run commands from the repository root:

```bash
bash scripts/build.sh test
bash scripts/build.sh native
uv venv .tmp/test-env --python 3.12
.tmp/test-env/bin/python tests/test_cli.py /absolute/path/to/sqlite-stream
```

Python is only a process-test driver; the executable has no Python dependency.
The CLI suite covers concurrent WAL writes and DDL, cancellation, pipe deadlines,
resource caps, no-clobber publication and Linux `/dev/full` failures.
Native Zig tests cover typed data, complex schemas, malformed archives and
restricted SQL execution.

For a remote host, cross-compile the contract-test executable and transfer it
alongside the CLI:

```bash
bash scripts/build.sh test-binary x86_64-linux-musl
```

Run the installed `bin/sqlite-stream-tests` on that target. Cross-compilation
alone does not establish runtime support.
