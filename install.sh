#!/usr/bin/env bash
#
# Installer for cf-tunnel. Downloads the latest cf-tunnel.sh from GitHub and
# installs it as `cf-tunnel` on your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/tkumar1918/cf-auto/main/install.sh | bash
#
# Override the install directory:  PREFIX=/somewhere/bin  bash install.sh
#
set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/tkumar1918/cf-auto/main/cf-tunnel.sh"
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

echo "Installing ${BIN_NAME} -> ${DEST}/${BIN_NAME}"
tmp="$(mktemp)"
curl -fsSL "$RAW_URL" -o "$tmp"
# sanity-check it's the script, not an error page
head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash' || { echo "error: download didn't look like the script" >&2; rm -f "$tmp"; exit 1; }
install -m 0755 "$tmp" "${DEST}/${BIN_NAME}"
rm -f "$tmp"

# Warn about any missing runtime dependencies.
missing=()
for c in jq curl cloudflared; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "note: missing dependencies: ${missing[*]} (jq+curl required; cloudflared needed to run tunnels)"
fi

# PATH hint.
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "note: ${DEST} is not on your PATH. Add this to your shell profile:"
     echo "      export PATH=\"${DEST}:\$PATH\"" ;;
esac

echo "Done. Run:  ${BIN_NAME} --help"
