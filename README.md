# Backup-Squirrel

- macOS menu bar app that runs [restic](https://restic.net) backups to a Hetzner Storage Box over SFTP; modeled on Arq, slimmed down.
- Targets and plans live in `~/Library/Application Support/Backup-Squirrel/configuration.json`, the run history of the last 12 months in `history.json` next to it; repository passwords live in the Keychain.
- Built for the author's own use.
- No pull requests: benevolent dictator. Forks are welcome.

## Requirements

- macOS 26 or later
- Xcode 26 or later to build

## Build from source

- Build: `xcodebuild -project BackupSquirrel.xcodeproj -scheme BackupSquirrel -destination 'platform=macOS' build`
- Test: same command with `test` instead of `build`
- Lint: `xcrun swift-format lint --strict --recursive .`
- restic: the build downloads the pinned restic release (`Scripts/fetch-restic.sh`), verifies its SHA-256, caches it in the git-ignored `.cache/` and signs it into `Contents/MacOS/restic`. The first build needs network access.
- Signing: ad hoc by default. To sign with your team, create the git-ignored `Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <team ID>` and `CODE_SIGN_STYLE = Automatic`.

## Debug launch arguments

- `-scenario <name>` picks the sample data and simulates this Mac: Full Disk Access, login item, notification permission and connected volumes. Names: `idle`, `running`, `warning`, `error`, `overdue`, `manual`, `incomplete`, `check-errors`, `check-failed`, `check-overdue`, `no-full-disk-access`, `no-login-item`, `notifications-denied`, `empty`. Without it the app loads its saved state, asks this Mac and backs up for real; only then does it schedule runs.
- `-openWindow history|plan` opens the main window at launch.
- `-renderSnapshots <directory>` renders windows (also with Increase Contrast and Reduce Transparency), sheets, icons, status menu and menu bar dumps with the notifications into the directory, checks that the open menu updates live, and quits.
- The app registers itself as login item only when it runs from `/Applications`, never from a build folder.

## License

- MIT, see [LICENSE](LICENSE).
