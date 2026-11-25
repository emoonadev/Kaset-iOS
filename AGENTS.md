# Contributor and agent guide

Instructions for anyone, human or AI agent, who changes this repository. `CLAUDE.md` is a
symlink to this file, so Claude Code, Codex and other agents all read the same rules. Edit
`AGENTS.md` only; never replace the symlink with a copy.

Spool is a native SwiftUI YouTube Music client for **iOS/iPadOS and macOS**, built from one
codebase with XcodeGen. See [`README.md`](README.md) for the architecture and
[`ROADMAP.md`](ROADMAP.md) for what is planned.

## Hard rules

Every pull request must follow these four rules. A PR that breaks one is not ready to merge.

### 1. Every feature ships on iOS and macOS

Spool is one app on two platforms. A feature, enhancement or fix must work on **both** the
`KasetiOS` and `KasetMac` targets in the same PR.

- Put logic, models, parsers and playback code in shared folders (`Core/`, `Playback/`,
  `Auth/`, `Features/`). They are compiled into both targets.
- Platform-specific UI goes in the right shell: `Features/Shell` and the iOS-only views excluded
  from `KasetMac` in `project.yml` for iOS, `Sources/Mac/` for macOS. When a feature appears in
  the iOS shell (tab, Now Playing, mini player), add its macOS counterpart (sidebar, player
  bar, side panel), and the reverse.
- Prefer the cross-platform helpers in `Sources/App/Platform.swift` (`PlatformImage`,
  `.trailingBar`, `inlineNavigationTitle()`, ...) to inline `#if os(...)` blocks. Add a new
  helper there when you need the same platform split more than once.
- Use `#if os(iOS)` / `#if os(macOS)` only for APIs that do not exist on the other platform,
  and keep a reasonable behaviour on both sides of the condition.
- Strings go in `Localizable.xcstrings` with English and French values, on both platforms.

**The only exception** is a feature that the contributor explicitly declares platform-specific,
because the platform cannot support it (for example lock-screen controls on iOS, or menu bar
commands on macOS) or because it is out of scope by decision. In that case the PR description
must say so in a **Platform scope** line, with the reason, for example:

> Platform scope: iOS only. Visual Intelligence is not available on macOS.

Agents must never decide on their own that a feature is single-platform. If you cannot see how
to support the other platform, ask the contributor instead of skipping it.

### 2. The version is one step above `main` (minor or major)

The version lives in `project.yml` as `MARKETING_VERSION` and follows
[Semantic Versioning](https://semver.org) (`MAJOR.MINOR.PATCH`).

- **The bump is relative to `main`, the released version, not to `develop`.** What is merged in
  `develop` is not released yet, so bumping again on top of it is pointless: every change
  waiting in `develop` ships together in the next release.
  - If `develop` still has the same `MAJOR.MINOR` as `main`, the PR bumps it one step.
  - If `develop` is already above `main`, the PR keeps that version. It only bumps again when
    its change needs a bigger step than the one already made (a major change while `develop`
    only has a minor bump: go to the next major).
- **Choosing the step**, according to the work done:
  - **Major** (`1.4` → `2.0`): breaking or very large changes. Examples: a change that drops
    saved data, settings or sign-in sessions, a migration users notice, raising the minimum OS
    version, removing a feature, a full redesign of the app.
  - **Minor** (`1.4` → `1.5`): everything else that is merged. New features, enhancements, bug
    fixes, refactors, performance work, localization, documentation and tooling.
  - When major, reset minor to zero (`1.4` → `2.0`).
- **Never set the patch number.** `MARKETING_VERSION` holds `MAJOR.MINOR` only. The release
  workflow (`.github/workflows/release.yml`) computes the patch on every update of `main` from the
  existing `vMAJOR.MINOR.N` tags, starting at `.0` after a bump.
- **Bump both app targets together**: `KasetiOS` and `KasetMac` must always have the same
  `MARKETING_VERSION`. Leave `CURRENT_PROJECT_VERSION` alone; the release workflow stamps the
  build number.
- If `develop` moved while the PR was open, rebase and keep the version `develop` has, unless
  the rule above asks for a bigger step.
- State the version and the reason in the PR description, compared with `main`, for example
  `Version: 1.4 → 1.5 (new feature: artist mixes)` or `Version: 1.5, unchanged (develop is
  already above main 1.4)`.

### 3. Everything is in English

Code, identifiers, comments, commit messages, branch names, PR titles and descriptions,
documentation and these instructions are written in English. User-facing strings are the only
exception: they are localized through `Localizable.xcstrings` (English is the source language,
French is the translation).

### 4. Every PR targets `develop`

All work lands on `develop` first; `main` is the release branch and never receives a PR.

- Branch from `develop` and open the PR against `develop` (it is the default branch, so
  `gh pr create` and the GitHub UI pick it automatically). Never open a PR against `main`.
- `develop` is protected: no direct pushes, no force pushes, and CI must pass. It only changes
  through a PR merged by the maintainer. Agents open PRs but never merge them.
- Once a day, the *Merge develop into main* workflow (`.github/workflows/sync-main.yml`)
  fast-forwards `main` to `develop` when `develop`'s CI is green, then triggers the release.
  Never push or merge into `main` by hand.

## Workflow

1. Branch from `develop` with a descriptive prefix: `feat/`, `fix/`, `refactor/`, `perf/`,
   `docs/`, `ci/`, `chore/` (for example `feat/sleep-timer`).
2. Make the change on both platforms (rule 1) and check the version against `main` (rule 2).
3. Run `xcodegen generate` after adding, removing or moving files. The Xcode project is
   generated and not committed.
4. Build both targets and run the tests (see below) before opening the PR.
5. Update `README.md` (features, limitations) and `ROADMAP.md` (move items to *Shipped*) when
   the change affects them.
6. Open a PR against `develop` (rule 4). Keep it focused on one topic. The maintainer reviews
   and merges it; the daily job ships it to `main`.

### Build and test

```bash
xcodegen generate

# iOS: build and run the unit tests
xcodebuild test \
  -project KasetiOS.xcodeproj -scheme KasetiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO

# macOS: build
xcodebuild build \
  -project KasetiOS.xcodeproj -scheme KasetMac \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

CI (`.github/workflows/ci.yml`) runs the same two jobs on every PR and on every push to
`develop` and `main`. Both must pass.

### Commits

- Short imperative subject line, under about 72 characters (`Add sleep timer to Now Playing`).
- One logical change per commit when practical; explain the why in the body if it is not
  obvious.

### Pull request description

Include:

- **Summary**: what changed and why.
- **Version**: compared with `main`: old → new, minor or major, with the reason, or unchanged
  because `develop` is already above `main` (rule 2).
- **Platform scope**: `iOS and macOS` (default), or the platform-specific exception and its
  reason (rule 1).
- **Testing**: what you built and ran, on which platforms and devices.
- Screenshots for UI changes, on both platforms when the UI differs.

## Project conventions

- **Swift 6** with strict concurrency, SwiftUI first, iOS 26 / macOS 26 deployment targets.
- **The hidden web view is the single source of truth for playback and the queue.** Native UI
  sends commands to `WebPlayer` and draws the mirrored `PlaybackState`; never keep a parallel
  player state.
- **Everything else goes through the InnerTube API.** Verify an endpoint against the real
  service (or Kaset's `api-explorer`) before writing a parser, and add a parser test with a
  sanitized fixture under `Tests/KasetiOSTests/Fixtures`.
- **Privacy**: never commit cookies, tokens, account identifiers or captured personal
  responses, and never log them. Fixtures use placeholders only.
- Add or update tests for parsers, state and logic you change. UI-only changes do not need
  unit tests but must be checked on both platforms.
- Do not rename targets, schemes, bundle identifiers or the `Kaset*` code names unless the PR is
  explicitly about that; the visible app name is `Spool`.
