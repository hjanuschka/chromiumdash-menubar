# AGENTS.md

## Project

`chromiumdash-menubar` is a tiny macOS menu bar app written in Swift/AppKit.
It shows current Chrome channel milestones and ChromiumDash schedule dates.

## Build

Use:

```bash
./scripts/build-app.sh
```

The app bundle is produced at:

```text
.build/Chromium Branches.app
```

## Release

Use:

```bash
./scripts/release.sh <version>
```

Example:

```bash
./scripts/release.sh 0.1.0
```

This will:

1. Build the release app bundle.
2. Create a zip in `.build/releases/`.
3. If `gh` is installed and authenticated, create or update the GitHub release and upload the zip.

Set `SKIP_GH_RELEASE=1` to only build the local artifact:

```bash
SKIP_GH_RELEASE=1 ./scripts/release.sh 0.1.0
```

## Git safety

Never use:

```bash
git add .
git add -A
git add -a
git commit -a
```

Always stage explicit files only.

Before committing, check:

```bash
git status
git diff --cached --name-only
```

## Style

Keep generated text and docs ASCII-only. Avoid smart quotes, em dashes, en dashes, and ellipses.
