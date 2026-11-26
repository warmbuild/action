#!/bin/sh
# Installs (or updates) the Warmbuild cache for local Xcode builds, in one command:
#   curl -fsSL https://warmbuild.dev/install.sh | sh
# 1. Downloads warmbuild.mjs from a pinned release of warmbuild/action (or, while that
#    release is not published yet, the latest one), checks it against the SHA-256 published beside
#    it, and installs it to ~/.warmbuild/bin. No sudo.
# 2. Adds ~/.warmbuild/bin to PATH in your shell profile: asks first in a terminal, otherwise only
#    prints the line (--add-to-path adds it without asking, --no-modify-path never does).
# 3. Signs in with a GitHub device code when there is no token yet (in a terminal; otherwise it
#    prints the step).
# 4. Runs `warmbuild start` when run inside a git repository, or when the cache is already set up
#    (an update): the LaunchAgent keeps the cache running across reboots. Otherwise it prints the
#    step.
# Run it again to update: it replaces the CLI and restarts the cache on the new version.
set -eu

version="1.13.1"
repo="warmbuild/action"
base="${WARMBUILD_DOWNLOAD_URL:-https://github.com/$repo/releases/download/v$version}"
latest="${WARMBUILD_LATEST_URL:-https://github.com/$repo/releases/latest/download}"
home="${WARMBUILD_HOME:-$HOME/.warmbuild}"
bin="$home/bin"
tty="${WARMBUILD_TTY:-/dev/tty}"

fail() {
  printf 'warmbuild install: %s\n' "$1" >&2
  exit 1
}

path_choice=ask
# Everything from here runs inside main, called on the last line: a download cut short
# (`curl | sh`) then runs nothing instead of half the script.
main() {
for arg in "$@"; do
  case "$arg" in
    --add-to-path) path_choice=yes ;;
    --no-modify-path) path_choice=no ;;
    *) fail "unknown option $arg (--add-to-path or --no-modify-path)" ;;
  esac
done

# Someone at a terminal: stdout is one and the terminal can be read (stdin is curl's pipe).
interactive=0
if [ "${WARMBUILD_INTERACTIVE:-}" = "1" ]; then
  interactive=1
elif [ "${WARMBUILD_INTERACTIVE:-}" != "0" ] && [ -t 1 ] && { : < "$tty"; } 2> /dev/null; then
  interactive=1
fi

# Asks a yes/no question on the terminal; the default is yes.
ask() {
  printf '%s [Y/n] ' "$1"
  answer=""
  read -r answer < "$tty" || answer=n
  case "$answer" in
    "" | [Yy] | [Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$(uname -s)" != "Darwin" ] && [ "${WARMBUILD_ANY_OS:-}" != "1" ]; then
  fail "Warmbuild's local cache is for macOS with Xcode 26 or newer; this is $(uname -s)."
fi

if ! command -v node > /dev/null 2>&1; then
  fail "Node.js 22.15 or newer is required and was not found. Install it (https://nodejs.org, or: brew install node) and run this again."
fi
# Objects travel compressed with zstd, which node:zlib has from 22.15: an older Node could not
# read what CI wrote.
node_new_enough="$(node -p '
  const [major, minor] = process.versions.node.split(".").map(Number);
  major > 22 || (major === 22 && minor >= 15) ? 1 : 0' 2> /dev/null || echo 0)"
if [ "$node_new_enough" != "1" ]; then
  fail "Node.js 22.15 or newer is required; found $(node --version). Update it (https://nodejs.org, or: brew upgrade node) and run this again."
fi
# The real path, so a version manager's per-shell shim does not end up in the wrapper.
node_path="$(node -p 'require("fs").realpathSync(process.execPath)')"

command -v curl > /dev/null 2>&1 || fail "curl is required."
if command -v shasum > /dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum > /dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
else
  fail "shasum or sha256sum is required to check the download."
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

printf 'Downloading warmbuild %s…\n' "$version"
# The bundle and its checksum always come from the same release.
pinned=1
if ! curl -fsSL --retry 3 -o "$tmp/warmbuild.mjs.sha256" "$base/warmbuild.mjs.sha256"; then
  printf 'warmbuild %s is not published yet; installing the latest release\n' "$version"
  base="$latest"
  version="(latest release)"
  pinned=0
  curl -fsSL --retry 3 -o "$tmp/warmbuild.mjs.sha256" "$base/warmbuild.mjs.sha256" || fail "could not download $base/warmbuild.mjs.sha256"
fi
curl -fsSL --retry 3 -o "$tmp/warmbuild.mjs" "$base/warmbuild.mjs" || fail "could not download $base/warmbuild.mjs"
expected="$(awk '{print $1}' "$tmp/warmbuild.mjs.sha256")"
actual="$(sha256 "$tmp/warmbuild.mjs")"
case "$expected" in
  *[!0-9a-f]* | "") fail "the published checksum is not a SHA-256" ;;
esac
[ ${#expected} -eq 64 ] || fail "the published checksum is not a SHA-256"
[ "$expected" = "$actual" ] || fail "checksum mismatch for warmbuild.mjs (expected $expected, got $actual); nothing was installed"

# Set up before this run: the cache was started here once (an update restarts it).
was_set_up=0
if [ -f "$home/warmbuild.pid" ] || [ -f "$home/repos.json" ] || [ -f "$HOME/Library/LaunchAgents/com.warmbuild.cache.plist" ]; then
  was_set_up=1
fi

mkdir -p "$bin"
# The home holds the compiled results of private source: this user's only.
chmod 700 "$home" 2> /dev/null || true
# Replace atomically: a running server keeps its open file until `warmbuild start` restarts it.
cp "$tmp/warmbuild.mjs" "$bin/warmbuild.mjs.new"
mv -f "$bin/warmbuild.mjs.new" "$bin/warmbuild.mjs"
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$node_path" "$bin/warmbuild.mjs" > "$bin/warmbuild.new"
chmod 755 "$bin/warmbuild.new"
mv -f "$bin/warmbuild.new" "$bin/warmbuild"
printf 'Installed warmbuild %s (sha256 %s) to %s/warmbuild\n' "$version" "$actual" "$bin"

# PATH, in the profile of the login shell.
path_line="export PATH=\"$bin:\$PATH\""
case "${SHELL:-}" in
  */bash) profile="$HOME/.bash_profile" ;;
  *) profile="$HOME/.zshrc" ;;
esac
new_shell=0
case ":$PATH:" in
  *":$bin:"*) ;;
  *)
    if grep -qsF "$bin" "$profile"; then
      new_shell=1
    else
      add=0
      if [ "$path_choice" = "yes" ]; then
        add=1
      elif [ "$path_choice" = "ask" ] && [ "$interactive" = "1" ] && ask "Add $bin to PATH in $profile?"; then
        add=1
      fi
      if [ "$add" = "1" ]; then
        printf '\n# Warmbuild\n%s\n' "$path_line" >> "$profile"
        printf 'Added %s to PATH in %s.\n' "$bin" "$profile"
        new_shell=1
      else
        printf '\nTo call it as warmbuild, add it to PATH (in %s):\n  %s\n' "$profile" "$path_line"
      fi
    fi
    ;;
esac

wb="$bin/warmbuild"
if [ "$pinned" = "0" ]; then
  # An older release than this installer expects: set up by hand.
  printf '\nNext:\n  %s login                  # once, GitHub device code\n  cd <your repository> && %s start\n' "$wb" "$wb"
  exit 0
fi

# Sign in once. The device code needs someone at a browser, so only in a terminal.
if "$wb" login --check > /dev/null 2>&1; then
  :
elif [ "$interactive" = "1" ]; then
  printf '\nSigning in with GitHub (once):\n'
  "$wb" login < "$tty" || printf 'Not signed in; builds use only this Mac'"'"'s cache until you run: warmbuild login\n'
else
  printf '\nNot signed in. Run once (it shows a GitHub device code):\n  %s login\n' "$wb"
fi

in_repo=0
if command -v git > /dev/null 2>&1 && git rev-parse --show-toplevel > /dev/null 2>&1; then
  in_repo=1
fi
if [ "$in_repo" = "1" ] || [ "$was_set_up" = "1" ]; then
  printf '\n'
  if [ "$interactive" = "1" ]; then
    "$wb" start < "$tty" || printf 'warmbuild start did not finish; see %s/warmbuild.log and run it again in your repository.\n' "$home"
  else
    "$wb" start < /dev/null || printf 'warmbuild start did not finish; see %s/warmbuild.log and run it again in your repository.\n' "$home"
  fi
else
  printf '\nNext, in your repository (the cache then also starts at every login):\n  cd <your repository> && %s start\n' "$wb"
fi
if [ "$new_shell" = "1" ]; then
  printf '\nOpen a new terminal (or run: exec %s) to call it as warmbuild.\n' "$(basename "${SHELL:-zsh}")"
fi
}

main "$@"
