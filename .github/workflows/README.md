# CI

`ci.yml` runs on pushes to `main`, pull requests, and manual dispatch. It runs HexCore tests and the Xcode app tests on Apple Silicon macOS, retaining the test result bundle. CI builds are signed ad hoc for testing; distribution uses the local Developer ID workflow.

Before app tests, CI runs `scripts/generate-project.sh`. This uses `.xcodegen-version` and bootstraps the checksummed official XcodeGen release if the runner does not have that exact version. `project.yml` and shared `.xcconfig` files define the project; generated project files and schemes are ignored. The app's `Package.resolved` inside `Hex.xcodeproj` and the independent HexCore lockfile stay committed. App tests require the resolved versions and link `IssueReportingTestSupport` explicitly.

No repository secrets are needed for CI. See [the distribution guide](../../docs/release-process.md) for local signing, notarization, and reviewed GitHub Releases.

`sparkle-feed.yml` deploys the appcast to GitHub Pages when a stable GitHub release is published, or by manual dispatch. Update archives are signed locally; the workflow only downloads and checks release metadata and deploys public files. It excludes drafts/prereleases and selects the highest Sparkle build number to prevent a late publication of an older release from rolling back the feed. Pages must be enabled with the GitHub Actions publishing source.

CI also runs release preparation and feed tests on Ubuntu independently of macOS runner availability. These tests use temporary repositories and simulated release actions; they do not sign, push, or publish anything.
