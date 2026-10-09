# Local Swift tests

Run SwiftPM tests through `Scripts/swift-test-isolated.sh`:

```sh
Scripts/swift-test-isolated.sh --filter SQLiteMailStoreTests
Scripts/swift-test-isolated.sh
```

The runner gives each invocation a short, private `TMPDIR` under `/private/tmp` and removes that directory when `swift test` exits, including on test failure. This contains temporary SQLite databases and their `-wal` and `-shm` files. It does not scan or remove older temp files, and it does not affect databases outside the invocation's `TMPDIR`. Direct `swift test` bypasses this containment; scripts that invoke tests should use the runner.

If a test needs to use a Unix domain socket, keep its path short enough for macOS. Avoid hardcoded `/tmp` test databases: put them under `FileManager.default.temporaryDirectory` and remove any per-test directory in teardown.
