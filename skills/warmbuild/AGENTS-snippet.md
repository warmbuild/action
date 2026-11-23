## Warmbuild (Xcode compilation cache and test selection)

This Mac may have the `warmbuild` CLI (`~/.warmbuild/bin/warmbuild`). It serves Xcode's compilation
cache from what CI built.

- Not installed (`command -v warmbuild` and `~/.warmbuild/bin/warmbuild` both missing, or an Xcode
  warning "Builds can reuse CI's compiled code"): with the user's OK, run in the repository
  `curl -fsSL https://warmbuild.dev/install.sh | sh -s -- --add-to-path`
  (or `brew install warmbuild/tap/warmbuild`). Then `warmbuild login`: it prints a GitHub URL
  and a code, then waits: run it in the background and show both to the user, who enters the code
  (it waits up to 15 minutes; GitHub access to the repository is enough). Then `warmbuild start` in the repository.

- `warmbuild status` (`--json`): on or off (exit code 0 or 1), account, last build's hits, misses,
  hit rate and MB, and each worktree's last build. `warmbuild start` in the repository turns the
  cache on for all its worktrees, also ones created later (a new worktree needs no setup; keep its
  path free of spaces); `warmbuild stop` turns it off, and builds then run without it.
  `warmbuild wait && xcodebuild …` waits until the cache serves builds (exit 124 after
  `--timeout <s>`, 1 when it is off). Exit codes: 0 ok, 1 error, 2 usage, 124 timeout.
- Building with it: `XCODE_XCCONFIG_FILE="$HOME/.warmbuild/warmbuild.xcconfig" xcodebuild …`
  (always safe; the project's include line alone does not reach Swift package targets). A
  low hit rate: `warmbuild doctor` prints the cause and the fix. Keep
  worktrees and `-derivedDataPath` out of `/tmp` (e.g. `~/Library/Caches/<name>/dd`): there they
  lose hits.
- `xcodebuild test … $(warmbuild tests --changed)`: only the tests the diff against the default
  branch reaches (empty output: all tests).
- CI report data, read-only, `--json` on each: `warmbuild builds`, `warmbuild report [--job <id>]`,
  `warmbuild findings`, `warmbuild why-miss <target>`, `warmbuild tests --slow|--flaky|--failing`.
- No shell: the MCP server `https://mcp.warmbuild.dev/mcp` has the same CI report
  data as tools (the user adds it to the agent's client).
- The user enters the `warmbuild login` code. Never read or print the Warmbuild token.
- If a Warmbuild command or the cache fails, `warmbuild stop` and build without it.
