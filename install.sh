#!/bin/sh
# Install Spark from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/curiosity-ai/spark/main/install.sh | sh
#
# Unpacks the self-contained release (the server, the runner, the CUDA kernels, the native RocksDB library and
# the front-end) into ~/.curiosity/spark, puts a launcher at ~/.curiosity/bin/spark, and adds that folder to
# PATH. Shared with curio and the orchestrator, which install into the same ~/.curiosity/bin. The runner needs no
# launcher: the server starts the one beside it.
#
# Settings, all optional:
#   SPARK_VERSION=v26.10.4242  a release tag instead of the latest release
#   SPARK_INSTALL=~/.curiosity where to install; the program goes in spark/, the launcher in bin/
#   SPARK_NO_MODIFY_PATH=1     leave the shell profile alone
#   GITHUB_TOKEN=...           a GitHub token (GH_TOKEN works too); lifts the API's anonymous rate limit
#
# Windows: use install.ps1 from PowerShell.
#
# Plain POSIX sh, so `| sh` works as well as `| bash`. Everything is inside main(), which runs on
# the last line: a download cut off halfway runs nothing.

set -eu

REPO="curiosity-ai/spark"
NAME="spark"
RUNNER="spark-runner"

say()  { printf '%s\n' "$*"; }
warn() { printf 'spark: %s\n' "$*" >&2; }
die()  { printf 'spark: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "this installer needs '$1'"; }

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# GET a URL to stdout (fetch) or to a file (download), with curl or wget. $2 / $3 is the Accept header.
fetch() {
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$TOKEN" ]; then
      curl -fsSL -H "Accept: ${2:-application/vnd.github+json}" -H "Authorization: Bearer $TOKEN" "$1"
    else
      curl -fsSL -H "Accept: ${2:-application/vnd.github+json}" "$1"
    fi
  elif [ -n "$TOKEN" ]; then
    wget -qO- --header="Accept: ${2:-application/vnd.github+json}" --header="Authorization: Bearer $TOKEN" "$1"
  else
    wget -qO- --header="Accept: ${2:-application/vnd.github+json}" "$1"
  fi
}
download() {
  accept="${3:-*/*}"
  if command -v curl >/dev/null 2>&1; then
    progress="-sS"
    [ -t 2 ] && progress="--progress-bar"
    if [ -n "$TOKEN" ]; then
      curl -fL $progress -H "Accept: $accept" -H "Authorization: Bearer $TOKEN" -o "$2" "$1"
    else
      curl -fL $progress -H "Accept: $accept" -o "$2" "$1"
    fi
  elif [ -n "$TOKEN" ]; then
    wget -q --header="Accept: $accept" --header="Authorization: Bearer $TOKEN" -O "$2" "$1"
  else
    wget -q --header="Accept: $accept" -O "$2" "$1"
  fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else return 1
  fi
}

detect_os() {
  case "$(uname -s)" in
    Linux)                           echo linux ;;
    Darwin)                          echo osx ;;
    MINGW* | MSYS* | CYGWIN*)        die "on Windows, install from PowerShell: irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex" ;;
    *) die "unsupported operating system: $(uname -s). Run it in Docker instead: see https://github.com/$REPO#as-a-container" ;;
  esac
}

detect_arch() {
  arch="$(uname -m)"
  # A shell running under Rosetta reports x86_64 on an Apple silicon Mac; install the native build.
  if [ "$1" = osx ] && [ "$arch" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    arch=arm64
  fi
  case "$arch" in
    x86_64 | amd64 | x64)  echo x64 ;;
    arm64 | aarch64)       echo arm64 ;;
    *) die "unsupported CPU architecture: $arch. Run it in Docker instead: see https://github.com/$REPO#as-a-container" ;;
  esac
}

# Reads the release JSON on stdin and prints "<browser url> <api url> <sha256 or ->" for one asset. No jq:
# the JSON is split at every comma and brace so each "key": value lands on a line of its own, and an
# asset's fields are read after its "name", which the GitHub API writes before its digest and URLs. The
# asset's own "url" comes before its "name", so it is remembered and claimed when the name matches.
asset_from_release() {
  tr ',{}' '\n\n\n' | awk -v want="$1" '
    function val(line) { sub(/^[^:]*:[ \t]*"/, "", line); sub(/".*$/, "", line); return line }
    /^[ \t]*"url"[ \t]*:/                                  { last = val($0) }
    /^[ \t]*"name"[ \t]*:/                                 { cur = val($0); if (cur == want && a == "") a = last }
    cur == want && /^[ \t]*"digest"[ \t]*:[ \t]*"sha256:/  { d = val($0); sub(/^sha256:/, "", d) }
    cur == want && /^[ \t]*"browser_download_url"[ \t]*:/  { u = val($0) }
    END { if (u != "") print u, (a == "" ? "-" : a), (d == "" ? "-" : d) }'
}

# Appends a line to a profile once; the comment above it marks it as ours.
add_line() {
  file="$1"; line="$2"
  [ -f "$file" ] && grep -Fq "$line" "$file" && return 0
  mkdir -p "$(dirname "$file")"
  printf '\n# curiosity\n%s\n' "$line" >> "$file"
  say "  added $BIN_DIR to PATH in $file"
}

add_to_path() {
  case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac

  if [ "${SPARK_NO_MODIFY_PATH:-}" = 1 ]; then
    NEW_PATH_HINT=1
    return 0
  fi

  # Written with $HOME rather than the expanded path when it lives under it, so a profile synced
  # between machines keeps working.
  case "$BIN_DIR" in
    "$HOME"/*) shown="\$HOME${BIN_DIR#"$HOME"}" ;;
    *)         shown="$BIN_DIR" ;;
  esac

  case "$(basename "${SHELL:-sh}")" in
    zsh)  add_line "${ZDOTDIR:-$HOME}/.zshrc" "export PATH=\"$shown:\$PATH\"" ;;
    bash)
      add_line "$HOME/.bashrc" "export PATH=\"$shown:\$PATH\""
      # A login shell (every new Terminal window on macOS) reads the first of these and not .bashrc.
      # Creating .bash_profile when .profile exists would hide .profile, so the existing one is used.
      login="$HOME/.bash_profile"
      for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        if [ -f "$f" ]; then login="$f"; break; fi
      done
      add_line "$login" "export PATH=\"$shown:\$PATH\""
      ;;
    fish) add_line "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/curiosity.fish" "fish_add_path \"$BIN_DIR\"" ;;
    *)    add_line "$HOME/.profile" "export PATH=\"$shown:\$PATH\"" ;;
  esac

  NEW_PATH_HINT=1
}

main() {
  OS="$(detect_os)"
  ARCH="$(detect_arch "$OS")"
  RID="$OS-$ARCH"
  INSTALL_ROOT="${SPARK_INSTALL:-$HOME/.curiosity}"
  BIN_DIR="$INSTALL_ROOT/bin"
  APP_DIR="$INSTALL_ROOT/spark"
  NEW_PATH_HINT=0
  # Program files are readable by everyone whatever the caller's umask, so a service account can run an
  # install made by root (sudo with umask 027 would otherwise lock it out of $INSTALL_ROOT).
  umask 022

  command -v curl >/dev/null 2>&1 || need wget
  need awk
  need tar

  if [ -n "${SPARK_VERSION:-}" ]; then
    case "$SPARK_VERSION" in v*) tag="$SPARK_VERSION" ;; *) tag="v$SPARK_VERSION" ;; esac
    api="https://api.github.com/repos/$REPO/releases/tags/$tag"
  else
    tag=""
    api="https://api.github.com/repos/$REPO/releases/latest"
  fi

  say "Installing Spark ($RID)"

  json="$(fetch "$api" 2>/dev/null || true)"
  [ -n "$tag" ] || tag="$(printf '%s' "$json" | tr ',' '\n' | awk -F'"' '/"tag_name"/ { print $4; exit }')"

  if [ -z "$tag" ]; then
    # The API refused (rate limit, proxy): the latest-release page redirects to the tag, which names the
    # archive. Asset names carry the version, so there is nothing to download without one.
    if command -v curl >/dev/null 2>&1; then
      tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null | sed -n 's|.*/releases/tag/||p')"
    fi
    if [ -z "$tag" ]; then
      if [ -z "$TOKEN" ]; then
        die "could not find the latest release of $REPO. If the GitHub API rate limit was hit, set GITHUB_TOKEN and try again. Releases: https://github.com/$REPO/releases"
      fi
      die "could not find the latest release of $REPO with the token given. Releases: https://github.com/$REPO/releases"
    fi
  fi

  version="${tag#v}"
  ASSET="$NAME-$version-$RID.tar.gz"
  found="$(printf '%s' "$json" | asset_from_release "$ASSET")"

  if [ -n "$found" ]; then
    url="$(printf '%s' "$found" | cut -d' ' -f1)"
    api_url="$(printf '%s' "$found" | cut -d' ' -f2)"
    digest="$(printf '%s' "$found" | cut -d' ' -f3)"
  elif [ -n "$json" ] && printf '%s' "$json" | grep -q '"tag_name"'; then
    # The release is there and has no archive for this platform.
    assets="$(printf '%s' "$json" | tr ',' '\n' | awk -F'"' '/"browser_download_url"/ { n = split($4, p, "/"); printf "%s%s", sep, p[n]; sep = ", " }')"
    die "release $tag has no build for $RID (it has: ${assets:-nothing}). Run it in Docker instead: see https://github.com/$REPO#as-a-container"
  else
    warn "could not read release $tag from the GitHub API; downloading $ASSET directly"
    url="https://github.com/$REPO/releases/download/$tag/$ASSET"
    api_url="-"
    digest="-"
  fi

  mkdir -p "$INSTALL_ROOT"
  # Unpacked next to the destination, so the final rename stays on one file system.
  work="$(mktemp -d "$INSTALL_ROOT/.spark-download.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  trap 'rm -rf "$work"; exit 130' INT TERM

  say "  downloading $tag: $url"
  # With a token the asset comes through its API URL, which is what a token authenticates against.
  if [ -n "$TOKEN" ] && [ "$api_url" != "-" ]; then
    download "$api_url" "$work/$ASSET" "application/octet-stream" || die "download failed: $api_url"
  else
    download "$url" "$work/$ASSET" || die "download failed: $url
Releases: https://github.com/$REPO/releases"
  fi

  if [ "$digest" = "-" ]; then
    # Older releases and the no-API path: every release also carries SHA256SUMS.
    sums_url="https://github.com/$REPO/releases/download/$tag/SHA256SUMS"
    sums_api="$(printf '%s' "$json" | asset_from_release SHA256SUMS | cut -d' ' -f2)"
    if [ -n "$TOKEN" ] && [ -n "$sums_api" ] && [ "$sums_api" != "-" ]; then
      download "$sums_api" "$work/SHA256SUMS" "application/octet-stream" 2>/dev/null || true
    else
      download "$sums_url" "$work/SHA256SUMS" 2>/dev/null || true
    fi
    [ -f "$work/SHA256SUMS" ] && digest="$(awk -v f="$ASSET" '$2 == f || $2 == "*" f { print $1; exit }' "$work/SHA256SUMS")"
    [ -n "$digest" ] || digest="-"
  fi

  if [ "$digest" != "-" ]; then
    if actual="$(sha256 "$work/$ASSET")"; then
      [ "$actual" = "$digest" ] || die "checksum mismatch for $ASSET: expected $digest, got $actual"
      say "  sha256 verified"
    else
      warn "no sha256sum or shasum; skipping the checksum"
    fi
  else
    warn "no checksum published for $ASSET; installing it unverified"
  fi

  # Owned by whoever installs, not by the build machine's uid stored in the archive.
  tar --no-same-owner -xzf "$work/$ASSET" -C "$work" || die "could not unpack $ASSET"
  unpacked="$work/$NAME-$version-$RID"
  [ -x "$unpacked/$NAME" ]   || die "$ASSET does not hold $NAME-$version-$RID/$NAME"
  [ -x "$unpacked/$RUNNER" ] || die "$ASSET does not hold $NAME-$version-$RID/$RUNNER"

  if [ "$OS" = osx ]; then
    xattr -dr com.apple.quarantine "$unpacked" 2>/dev/null || true
  fi

  # Swapped in whole: a running server and its runners keep the files they opened until they are restarted. The
  # data and the models are not in here (SPARK_STORAGE), so nothing but the program is replaced.
  rm -rf "$APP_DIR.old"
  [ -d "$APP_DIR" ] && mv "$APP_DIR" "$APP_DIR.old"
  mv "$unpacked" "$APP_DIR"
  rm -rf "$APP_DIR.old"
  trap - EXIT INT TERM
  rm -rf "$work"

  # A launcher rather than a symbolic link: the server finds the runner, wwwroot/ and its native library beside the
  # real file, and resolving a link to get there is the runtime's business on one platform and not another.
  mkdir -p "$BIN_DIR"
  launcher="$BIN_DIR/$NAME"
  printf '#!/bin/sh\nexec "%s/%s" "$@"\n' "$APP_DIR" "$NAME" > "$launcher"
  chmod 755 "$launcher"

  if [ "$OS" = linux ] && ldd --version 2>&1 | grep -qi musl; then
    warn "this looks like a musl system (Alpine); the release needs glibc. If it does not start, run it in Docker."
  fi

  say "  installed $APP_DIR"
  say "  launcher  $launcher"
  add_to_path

  # The runner loads the NVIDIA driver and cuBLAS 12 itself; without cuBLAS it runs on the CPU only.
  if [ "$OS" = linux ] && command -v nvidia-smi >/dev/null 2>&1 \
     && ! { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -q 'libcublas\.so\.12'; then
    warn "an NVIDIA GPU is present but libcublas.so.12 was not found: install cuBLAS 12 (the CUDA 12 toolkit or libcublas-12-x) to run models on it, or use the Docker image curiosityai/spark."
  fi

  say ""
  say "Spark $tag is installed."
  if [ "$NEW_PATH_HINT" = 1 ]; then
    say "Open a new terminal, or run this one first:"
    if [ "$(basename "${SHELL:-sh}")" = fish ]; then
      say "  fish_add_path \"$BIN_DIR\""
    else
      say "  export PATH=\"$BIN_DIR:\$PATH\""
    fi
  fi
  say "Then start it with a management password (data and models go to ./storage unless SPARK_STORAGE says otherwise):"
  say "  SPARK_ADMIN_PASSWORD='choose-a-password' SPARK_STORAGE=\"\$HOME/.curiosity/spark-data\" $NAME"
  say "and open http://localhost:8080 (SPARK_PORT changes the port)."
}

main "$@"
