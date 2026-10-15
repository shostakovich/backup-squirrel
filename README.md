# Backup-Squirrel

- macOS menu bar app that runs [restic](https://restic.net) backups to a Hetzner Storage Box over SFTP; modeled on Arq, slimmed down.
- Current state: UI prototype with sample data. No restic, Keychain or networking yet.
- Built for the author's own use.
- No pull requests: benevolent dictator. Forks are welcome.

## Requirements

- macOS 26 or later
- Xcode 26 or later to build

## Build from source

- Build: `xcodebuild -project BackupSquirrel.xcodeproj -scheme BackupSquirrel -destination 'platform=macOS' build`
- Test: same command with `test` instead of `build`
- Lint: `xcrun swift-format lint --strict --recursive .`
- Signing: ad hoc by default. To sign with your team, create the git-ignored `Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <team ID>` and `CODE_SIGN_STYLE = Automatic`.

## Debug launch arguments

- `-scenario <name>` picks the sample data and simulates this Mac: Full Disk Access, login item, notification permission and connected volumes. Names: `idle`, `running`, `warning`, `error`, `overdue`, `manual`, `incomplete`, `check-errors`, `check-failed`, `check-overdue`, `no-full-disk-access`, `no-login-item`, `notifications-denied`, `empty`. Without it the app shows `running` and asks this Mac.
- `-openWindow history|plan` opens the main window at launch.
- `-renderSnapshots <directory>` renders windows (also with Increase Contrast and Reduce Transparency), sheets, icons, status menu and menu bar dumps with the notifications into the directory, checks that the open menu updates live, and quits.
- The app registers itself as login item only when it runs from `/Applications`, never from a build folder.

## License

- MIT, see [LICENSE](LICENSE).
