---
name: warmbuild
description: Reference for the warmbuild CLI on a Mac — the Warmbuild compilation cache for Xcode builds (xcodebuild, Xcode app) that CI fills, and test selection. Use when building or testing an Xcode project on a machine with Warmbuild installed, or when the user asks about Warmbuild, its cache hits and misses, or which tests a change reaches.
---

# Warmbuild CLI

Warmbuild serves Xcode's compilation cache from what CI compiled on the default branch. On a Mac
the CLI runs a local cache server and an xcconfig that points Xcode and xcodebuild at it. The cache
is optional: builds work the same without it.

## Install, sign in, turn on and off

| Command | What it does |
| --- | --- |
| `curl -fsSL https://warmbuild.dev/install.sh \| sh` | Installs `~/.warmbuild/bin/warmbuild` (macOS, Node 22.15+), and in a repository also starts the cache. Without a terminal it does not sign in or edit the shell profile; it prints those steps. The daemon updates itself daily; `warmbuild update` does it now. |
| `warmbuild login` | GitHub device flow: prints a URL and a code, then waits up to 15 minutes for the user to enter the code in a browser. Run it in the background (or let the user run it) and show them both. Stores a read-only token in the macOS Keychain. |
| `warmbuild start` | In a repository: starts the cache server (LaunchAgent), writes `~/.warmbuild/warmbuild.xcconfig`, and maps every worktree of the repository the way CI maps its checkout, so builds in any worktree (also several at once) share CI's keys. Once per repository. |
| `warmbuild stop` | Stops the server and empties the xcconfig; builds then run without the cache. |
| `warmbuild wait [--timeout <s>]` | Blocks until the cache serves builds: exit 0 ready, 124 still not ready after the timeout (default 900 s), 1 at once when the cache is off. `warmbuild wait && xcodebuild …`. |
| `warmbuild link [dir]` | Links the repository at `dir` (default `.`) too, and points `/tmp/warmbuild/src` at this checkout. `#filePath` and the debugger resolve through that link; the daemon also moves it to the checkout of each `xcodebuild` it sees start. |
| `warmbuild run -- xcodebuild …` | One build with its own short-lived server, without the LaunchAgent. |

`warmbuild` may not be on PATH; `~/.warmbuild/bin/warmbuild` is the same command.

`start --quiet` and `stop --quiet` print one line (`Warmbuild: on (read-only)`, `Warmbuild: off`, …).
Exit codes for every command: 0 ok, 1 error (`status`: off), 2 wrong command line, 124 gave up
waiting. `warmbuild run` exits with the build's code.

## Building with the cache

Pass `XCODE_XCCONFIG_FILE`: it reaches every target, Swift package targets included.
`#include? "warmbuild.local.xcconfig"` in the project's xcconfig reaches only the project's own
targets, so plain `xcodebuild …` is enough only for a project without Swift packages
(`warmbuild doctor` says which):

```sh
XCODE_XCCONFIG_FILE="$HOME/.warmbuild/warmbuild.xcconfig" xcodebuild …
```

Passing it is harmless when the project includes it too, so always pass it. When a build hits little,
`warmbuild status` names the likely cause and `warmbuild doctor` lists every check with its fix. Keys equal CI's only
for the same Xcode version, configuration, destination and architecture as the CI job that filled
the cache. Xcode 26 also puts the DerivedData path into Swift keys: Swift compilations hit only when
DerivedData is at the same path as on CI (Clang modules hit anywhere; Xcode 27 does not have this
limit). A `-derivedDataPath` or worktree below `/tmp` (or `/private/tmp`) loses hits: use
Xcode's default DerivedData or a folder in the home directory (e.g. `~/Library/Caches/<name>/dd`).
A new worktree needs no setup: the daemon picks it up within seconds; one whose path has a space
cannot be mapped (`unmappable` in `status --json`) and builds without CI's keys. `#filePath` is `/tmp/warmbuild/src/…` in every
worktree; tests that find files through it read the checkout that link points at.

## Status: hits and misses

`warmbuild status` prints whether the cache is on, the account, the linked repositories and their
projects, the last build of all worktrees together and each worktree's own last build. Exit code 0 means on, 1 means off. `warmbuild status --json` prints (schema version 1: fields may be added; `schemaVersion` goes up only when one is renamed, removed or changes meaning):

| Field | |
| --- | --- |
| `schemaVersion`, `generatedAt` | `1`; when the report was made (ms) |
| `running`, `pid` | the server answers and the xcconfig points at it; the daemon's pid or `null` |
| `version`, `xcconfig` | the CLI version; the xcconfig's path |
| `mode` | `read-only` or `read-write` |
| `account`, `tokenExpiresAt` | signed-in account, or `null` |
| `sourceRoot` | where `/tmp/warmbuild/src` points |
| `checkouts`, `unmappable` | every mapped worktree; worktrees with a space in their path, which cannot be mapped |
| `repositories`, `projects`, `conflicts` | linked repositories (git directories); project name → directory below the checkout root; names at two places in as many worktrees each, not mapped |
| `worktrees` | each worktree: `path`, `counted` (has its own socket, so its builds are counted apart), `lastBuild` (`hits`, `misses`, `hitRate`, `startedAt`, `endedAt`) or `null`, `disk` (`bytes`, `derivedData[]`: its DerivedData folders, measured every 10 min) or `null` |
| `lastBuild` | all worktrees together: `hits`, `misses`, `hitRate` (0–1), `remoteHits` (from Warmbuild), `localHits` (this Mac), `mbDown`, `mbUp`, `httpFailures`, `failedRequests` (by reason: `network`, `token`, `key`, `account`, `server`), `startedAt`, `endedAt` (ms) |
| `localTier` | the server's store: `path`, `bytes`, `measuredAt` (`null` before the first measurement), `lastGcAt` and `maxBytes` (the last sweep and its cap; `null` before the first), `freeBytes` on its disk now, `lowDisk` below 10 GiB free |
| `diagnosis` | when the cache is off or the last build hit little: `id`, `detail`, `fix`; else `null` |

The last build is the last burst of cache traffic, split at 20 s without lookups. A miss is a
compilation whose key is in neither this Mac's cache nor Warmbuild's. Keys differ when the Xcode
version, SDK, configuration, destination, build settings or sources differ from what CI built, and
for code CI has not built yet. `httpFailures` above 0 means Warmbuild could not be reached or
refused; `failedRequests` says why (`token`: run `warmbuild login`; `account`: not approved or
over quota; `network`: offline). The build then used only this Mac's cache. For a target that
missed, `warmbuild why-miss <target>` compares it with the CI jobs that built it. Disk full: the
largest `worktrees[].disk` are DerivedData folders of worktrees; deleting them is safe.

## Test selection

`warmbuild tests --changed` prints `xcodebuild` arguments for the tests the working tree's diff
reaches: the diff against the merge base with origin's default branch, including uncommitted and
untracked files. A one-line reason goes to stderr.

```sh
xcodebuild test … $(warmbuild tests --changed)
```

- Empty output: every test runs. `-skip-testing` for every target: the diff reaches no test.
- `--format xcodebuild|swift|json|markdown`. `swift` prints a `swift test --filter` pattern (empty
  when everything runs, `^$` when nothing is reached):
  `p=$(warmbuild tests --changed --format swift); swift test ${p:+--filter "$p"}`.
- `--base <ref>`, `--depth 2`, `--max-files 40`, `--ignore <regex>`, `--always Target[/Suite]`
  (always run), `--no-hints` (skip recent default-branch failures, which come from Warmbuild).

## CI reports

Read-only views of the account's CI reports (names, durations, counts; no source or logs). The
repository defaults to the checkout's GitHub origin; `--repo owner/name` overrides it. All take
`--json`; shapes are in the Warmbuild docs (`docs/dev-cache.md`, "CI reports from the command line").

| Command | Output |
| --- | --- |
| `warmbuild builds [--branch <b>] [--limit <n>]` | recent CI jobs: id, ref, duration, cache hits/misses/rate, test results |
| `warmbuild report [--job <id>]` | one job (default newest): time per category, targets by compile time with cache hits and misses, slowest tasks and tests |
| `warmbuild findings` | the dashboard's findings with estimated time per job |
| `warmbuild insights [--local]` | which module recompiles most and pulls others with it, and which of its parts could move into a package (share of pull requests spared, time saved) |
| `warmbuild tests --slow\|--flaky\|--failing [--limit <n>]` | the slowest tests, tests that passed only on a retry, or tests that failed every run, over recent CI jobs |
| `warmbuild why-miss <target> [--jobs <n>]` | a target's hits and misses across recent jobs, and which of Xcode, runner, ref, event and commit differ from the last job without misses; it cannot see inside cache keys |

No shell? Use the MCP server: the same CI report data, read-only, as the tools `list_repositories`,
`latest_ci_report`, `why_cache_miss`, `tests`, `pr_test_selection` and `build_insights` at
`https://mcp.warmbuild.dev/mcp` (remote, Streamable HTTP, GitHub sign-in; the user
adds it to the client).

A request that fails prints `warmbuild: <reason>` on stderr and exits 1 (not signed in, no
repository, unknown job).

## Rules

- Never read, print or log the token: not with `security`, not from `~/.config/warmbuild`, not
  from the environment. `warmbuild status` shows the account.
- The user enters the `warmbuild login` code; `--write` (uploading from this Mac) is the user's call.
- When a Warmbuild command fails, or a build reports a compilation cache or remote service error,
  `warmbuild stop` turns the cache off and the build runs as a plain local build.
