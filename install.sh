#!/usr/bin/env bash
#
# Installer for cf-tunnel. Downloads the latest cf-tunnel.sh from GitHub and
# installs it as `cf-tunnel` on your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/tkumar1918/cf-auto/main/install.sh | bash
#
# It also auto-installs missing deps (jq, cloudflared) into the same directory.
#
# Pin a version:        REF=v1.0.0 bash install.sh   (default: main = latest)
# Install directory:    PREFIX=/somewhere/bin bash install.sh
# Skip dep install:     SKIP_DEPS=1 bash install.sh
#
set -euo pipefail

REF="${REF:-main}"
RAW_URL="https://raw.githubusercontent.com/tkumar1918/cf-auto/${REF}/cf-tunnel.sh"
BIN_NAME="cf-tunnel"

# Pick an install directory: $PREFIX, else /usr/local/bin if writable, else ~/.local/bin.
if [[ -n "${PREFIX:-}" ]]; then
  DEST="$PREFIX"
elif [[ -w /usr/local/bin ]]; then
  DEST="/usr/local/bin"
else
  DEST="${HOME}/.local/bin"
fi
mkdir -p "$DEST"

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }

echo "Installing ${BIN_NAME} (${REF}) -> ${DEST}/${BIN_NAME}"
tmp="$(mktemp)"
curl -fsSL "$RAW_URL" -o "$tmp"
# Sanity-check it's the script, not an error page.
head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash' || { echo "error: download didn't look like the script" >&2; rm -f "$tmp"; exit 1; }
install -m 0755 "$tmp" "${DEST}/${BIN_NAME}"
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Auto-install runtime dependencies (jq, cloudflared)
# ---------------------------------------------------------------------------
# Static binaries go into $DEST (no root). Set SKIP_DEPS=1 to skip. curl itself
# is assumed present (it bootstrapped this script).
have() { command -v "$1" >/dev/null 2>&1; }

# Print the normalized arch for release binaries, or empty if unsupported.
dl_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *)             echo "" ;;
  esac
}

# Install a package via the distro package manager (best-effort; may use sudo).
pkg_install() {
  local sudo=""; [[ "$(id -u)" -ne 0 ]] && have sudo && sudo="sudo"
  if   have apt-get; then $sudo apt-get update -qq && $sudo apt-get install -y "$1"
  elif have dnf;     then $sudo dnf install -y "$1"
  elif have yum;     then $sudo yum install -y "$1"
  elif have pacman;  then $sudo pacman -Sy --noconfirm "$1"
  elif have zypper;  then $sudo zypper install -y "$1"
  elif have apk;     then $sudo apk add "$1"
  elif have brew;    then brew install "$1"
  else return 1; fi
}

# Ensure jq is present: download a static binary into $DEST, else package manager.
install_jq() {
  have jq && return 0
  echo "Installing jq..."
  local os arch; arch="$(dl_arch)"
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=macos ;; *) os="" ;; esac
  if [[ -n "$os" && -n "$arch" ]] && \
     curl -fsSL "https://github.com/jqlang/jq/releases/latest/download/jq-${os}-${arch}" -o "${DEST}/jq"; then
    chmod +x "${DEST}/jq"; return 0
  fi
  pkg_install jq   # fallback for unusual arch / OS
}

# Ensure cloudflared is present: brew if available, else a static binary in $DEST.
install_cloudflared() {
  have cloudflared && return 0
  echo "Installing cloudflared..."
  if have brew; then if brew install cloudflared; then return 0; fi; fi
  local arch; arch="$(dl_arch)"
  if [[ "$(uname -s)" == Linux && -n "$arch" ]] && \
     curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o "${DEST}/cloudflared"; then
    chmod +x "${DEST}/cloudflared"; return 0
  fi
  if [[ "$(uname -s)" == Darwin && -n "$arch" ]]; then
    local t; t="$(mktemp).tgz"
    if curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${arch}.tgz" -o "$t" \
       && tar -xzf "$t" -C "$DEST" cloudflared; then
      chmod +x "${DEST}/cloudflared"; rm -f "$t"; return 0
    fi
    rm -f "$t"
  fi
  return 1
}

if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
  install_jq          || echo "warn: couldn't auto-install jq — please install it manually."
  install_cloudflared || echo "warn: couldn't auto-install cloudflared — see https://pkg.cloudflare.com/"
fi

# Final dependency report.
missing=()
for c in jq curl cloudflared; do have "$c" || missing+=("$c"); done
[[ "${#missing[@]}" -gt 0 ]] && echo "note: still missing: ${missing[*]}"

# PATH hint.
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "note: ${DEST} is not on your PATH. Add this to your shell profile:"
     echo "      export PATH=\"${DEST}:\$PATH\"" ;;
esac

echo "Done. Run:  ${BIN_NAME} --help"
