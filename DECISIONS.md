# Decisions

## 0001. Drive the restic CLI instead of rustic

Accepted, 2026-10-15

- **Context:** The backup engine must be mature and reliable; rustic is still labelled beta, and rustic-core's API is pre-1.0 and would need a Rust bridge into Swift.
- **Decision:** Run the restic command-line tool as a child process and read its JSON output instead of using rustic or linking rustic-core.
- **Consequences:** The app parses CLI output and exit codes rather than calling a typed API, and depends on restic keeping its JSON messages stable.

## 0002. Bundle a pinned restic in the app

Accepted, 2026-10-15

- **Context:** Backups must not break because a package manager upgraded or moved restic, and a GUI app cannot rely on the user's PATH.
- **Decision:** Ship a pinned restic release inside the app bundle; a build script downloads it and verifies its SHA-256 checksum. Homebrew's restic is not used.
- **Consequences:** Security fixes in restic reach the app only after bumping the pinned version and rebuilding.

## 0003. Fixed retention policy

Accepted, 2026-10-15

- **Context:** The app is built for one owner who wants the same thinning for every plan, and every setting is one more thing to get wrong.
- **Decision:** Retention is fixed in code: everything from the last 24 hours, one snapshot per day for 30 days, per week for 52 weeks and per month without limit; it is not a setting.
- **Consequences:** Changing the policy means a code change and a new build, and it applies to all plans at once.
