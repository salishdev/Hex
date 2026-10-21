# CI

`ci.yml` runs on pushes to `main`, pull requests, and manual dispatch. It runs HexCore tests and the Xcode app tests on Apple Silicon macOS, retaining the test result bundle. CI builds are signed ad hoc for testing; distribution uses the local Developer ID workflow.

No repository secrets are needed for CI. See [the distribution guide](../../docs/release-process.md) for local signing, notarization, and reviewed GitHub Releases.
