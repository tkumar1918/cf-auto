#!/usr/bin/env bash
#
# cf-tunnel.sh — Cloudflare tunnel automation (token-only / API model)
#
# One credential does everything: no `cloudflared tunnel login`, no cert.pem,
# no local config files. All tunnel + routing state lives at Cloudflare and is
# driven through the v4 API. cloudflared is only needed to RUN a tunnel.
#
# One tunnel serves many subdomains (ingress rules). Run `cf-tunnel.sh --help`
# for the full command list.
#
# Requires: CLOUDFLARE_API_TOKEN (env var, or saved via `auth`) with:
#   Account -> Cloudflare Tunnel -> Edit
#   Zone    -> DNS               -> Edit
#   Zone    -> Zone              -> Read
# Optional: CLOUDFLARE_ACCOUNT_ID (otherwise derived from the zone).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults & globals
# ---------------------------------------------------------------------------
API="https://api.cloudflare.com/client/v4"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cf-tunnel"
CONFIG_FILE="${CONFIG_DIR}/config"
RUN_DIR="${CONFIG_DIR}/run"   # pid + log files for backgrounded tunnels

ACTION=""
NAME=""
SUBDOMAIN=""
HOSTNAME_OVERRIDE=""
DOMAIN=""            # resolved from --domain, saved config, or interactive pick
DOMAIN_EXPLICIT=0    # 1 when --domain was passed (overrides saved default)
ASSUME_YES=0
BACKGROUND=0         # 1 when `up` should run detached
FOLLOW=0             # 1 when `logs` should tail -f
declare -a MAPS=()

_ACCT=""   # memoized account id
_ZONE=""   # memoized zone id (for $DOMAIN)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_INF=$'\033[36m'; C_OK=$'\033[32m'; C_WRN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RST=""; C_INF=""; C_OK=""; C_WRN=""; C_ERR=""
fi
info() { printf '%s==>%s %s\n' "$C_INF" "$C_RST" "$*"; }
ok()   { printf '%s✓%s %s\n'   "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s!%s %s\n'   "$C_WRN" "$C_RST" "$*" >&2; }
die()  { printf '%s✗%s %s\n'   "$C_ERR" "$C_RST" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
cf-tunnel.sh — Cloudflare tunnel automation (token-only, no login)

Usage:
  cf-tunnel.sh <action> <name> [options]

Actions:
  create <name> --map sub=service[,...]
                    Create/update the tunnel, set its ingress config, and route
                    each subdomain's DNS CNAME. Re-running adds/updates (idempotent).
                    Example: create webspacehub --map app=3000,api=8002
  up <name> [-d]    Run the tunnel (foreground). With -d/--background, run
                    detached (writes pid + log under ~/.config/cf-tunnel/run).
  stop <name>       Stop a backgrounded tunnel.
  status [name]     Show running/stopped state of backgrounded tunnels.
  logs <name> [-f]  Show a backgrounded tunnel's log (-f to follow).
  remove <name> -s <sub>
                    Remove one subdomain: its ingress entry + its DNS CNAME.
  destroy <name>    Delete the whole tunnel, its DNS records, and its config.
  show [name]       Show one tunnel (or every tunnel) and its subdomains.
  list              List all tunnels in the account.
  domain [name]     Show/choose the default domain (saved for future runs).
  auth [token]      Save an API token to the config (verified; prompts if omitted).

Options:
  -m, --map <sub=service[,...]>  Mappings for create, comma-separated. Shorthand:
                             app=3000            -> http://localhost:3000
                             app=localhost:3000  -> http://localhost:3000
                             app=http://h:3000   -> as-is
  -s, --subdomain <sub>    Subdomain label                      (remove)
      --hostname <fqdn>    Full hostname (overrides subdomain)  (remove)
      --domain <domain>    Zone/apex domain (overrides saved default)
  -d, --background         Run detached                         (up)
  -f, --follow             Follow the log (tail -f)             (logs)
  -y, --yes                Don't prompt (auto-confirm move/destroy)
  -h, --help               Show this help

Auth (required): a single API token, no `cloudflared tunnel login` needed.
  Permissions: Account>Cloudflare Tunnel>Edit, Zone>DNS>Edit, Zone>Zone>Read
  Provide it either way:
    export CLOUDFLARE_API_TOKEN=<token>     (env var, wins if set)
    cf-tunnel.sh auth <token>               (saved to config, chmod 600)
  Optional: export CLOUDFLARE_ACCOUNT_ID=<id>   (otherwise derived from the zone)

The default domain is chosen once (or via `domain`) and saved in:
  ~/.config/cf-tunnel/config

Examples:
  cf-tunnel.sh create webspacehub --map app=3000,api=8002
  cf-tunnel.sh up webspacehub
  cf-tunnel.sh remove webspacehub -s api
  cf-tunnel.sh destroy webspacehub
  cf-tunnel.sh show
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
add_maps() {
  local part; local IFS=','
  for part in $1; do [[ -n "$part" ]] && MAPS+=("$part"); done
}

parse_args() {
  [[ $# -gt 0 && "$1" != -* ]] && { ACTION="$1"; shift; }
  [[ $# -gt 0 && "$1" != -* ]] && { NAME="$1"; shift; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--map)        add_maps "${2:-}"; shift 2 ;;
      -s|--subdomain)  SUBDOMAIN="${2:-}"; shift 2 ;;
      --hostname)      HOSTNAME_OVERRIDE="${2:-}"; shift 2 ;;
      --domain)        DOMAIN="${2:-}"; DOMAIN_EXPLICIT=1; shift 2 ;;
      -d|--background|--detach) BACKGROUND=1; shift ;;
      -f|--follow)     FOLLOW=1; shift ;;
      -y|--yes)        ASSUME_YES=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "Unknown argument: $1 (try --help)" ;;
    esac
  done
  [[ -n "$ACTION" ]] || { usage; exit 0; }
}

resolve_hostname() {
  if [[ -n "$HOSTNAME_OVERRIDE" ]]; then echo "$HOSTNAME_OVERRIDE"
  elif [[ -n "$SUBDOMAIN" ]];     then echo "${SUBDOMAIN}.${DOMAIN}"
  else echo ""; fi
}

normalize_service() {
  local s="$1"
  [[ "$s" =~ ^[0-9]+$ ]] && s="localhost:${s}"
  if [[ "$s" == *"://"* || "$s" == http_status:* ]]; then echo "$s"; else echo "http://${s}"; fi
}

confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local reply; read -r -p "$1 [y/N] " reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# ---------------------------------------------------------------------------
# Cloudflare API
# ---------------------------------------------------------------------------
preflight_tools() {
  command -v jq   >/dev/null 2>&1 || die "jq not found (apt install jq)."
  command -v curl >/dev/null 2>&1 || die "curl not found."
}

preflight() {
  preflight_tools
  # Token resolution: CLOUDFLARE_API_TOKEN env wins; else the saved one.
  [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && CLOUDFLARE_API_TOKEN="$(config_get token)"
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "No API token. Set CLOUDFLARE_API_TOKEN, or run: $0 auth"
}

# --- tiny key=value config store (~/.config/cf-tunnel/config) ---------------
config_get() { [[ -f "$CONFIG_FILE" ]] && sed -n "s/^$1=//p" "$CONFIG_FILE" | head -n1; }
config_set() {
  mkdir -p "$CONFIG_DIR"
  local tmp; tmp="$(mktemp)"
  { [[ -f "$CONFIG_FILE" ]] && grep -v "^$1=" "$CONFIG_FILE" || true; echo "$1=$2"; } > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

# Interactively pick a domain from the zones the token can see, then save it.
pick_domain() {
  local zones; zones="$(api GET "/zones?per_page=50" | jq -r '.[].name')"
  [[ -n "$zones" ]] || die "This token can't see any zones (needs Zone>Read)."
  local -a list=(); local z
  while IFS= read -r z; do [[ -n "$z" ]] && list+=("$z"); done <<< "$zones"

  if [[ "${#list[@]}" -eq 1 ]]; then
    DOMAIN="${list[0]}"
  else
    info "Multiple domains available — choose the default:"
    local i
    for i in "${!list[@]}"; do printf '  %d) %s\n' "$((i+1))" "${list[$i]}"; done
    local choice
    read -r -p "Number [1-${#list[@]}]: " choice
    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#list[@]}" ]] \
      || die "Invalid selection."
    DOMAIN="${list[$((choice-1))]}"
  fi
  config_set domain "$DOMAIN"
  ok "Default domain set to ${DOMAIN} (saved in ${CONFIG_FILE})"
}

# Resolve DOMAIN: explicit --domain wins; else saved default; else pick once.
ensure_domain() {
  [[ "$DOMAIN_EXPLICIT" -eq 1 && -n "$DOMAIN" ]] && return
  DOMAIN="$(config_get domain)"
  [[ -n "$DOMAIN" ]] && return
  pick_domain
}

# Raw call: prints the full JSON response.
cf_raw() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -X "$method" "${API}${path}"
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(--data "$data")
  curl "${args[@]}"
}

# Checked call: prints compact `.result`; dies with the API error otherwise.
api() {
  local resp; resp="$(cf_raw "$@")" || die "Network error calling $2"
  if [[ "$(jq -r '.success // false' <<<"$resp")" != "true" ]]; then
    die "Cloudflare API error ($1 $2): $(jq -rc '.errors // .messages // "unknown"' <<<"$resp")"
  fi
  jq -c '.result' <<<"$resp"
}

# Fetch the zone once and memoize both its id and its owning account id.
# (Deriving the account id from the zone avoids needing account-list permission.)
_fetch_zone() {
  [[ -n "$_ZONE" ]] && return
  local z; z="$(api GET "/zones?name=${DOMAIN}")"
  _ZONE="$(jq -r '.[0].id // empty' <<<"$z")"
  [[ -n "$_ZONE" ]] || die "Zone '${DOMAIN}' not found for this token (needs Zone>Read)."
  _ACCT="${CLOUDFLARE_ACCOUNT_ID:-$(jq -r '.[0].account.id // empty' <<<"$z")}"
  [[ -n "$_ACCT" ]] || die "Could not determine account id. Set CLOUDFLARE_ACCOUNT_ID."
}
account_id() { _fetch_zone; echo "$_ACCT"; }
zone_id()    { _fetch_zone; echo "$_ZONE"; }

# ---------------------------------------------------------------------------
# Tunnel + config + DNS primitives
# ---------------------------------------------------------------------------
# Print a tunnel's id by name (empty if none).
tunnel_id() {
  local acct; acct="$(account_id)"
  api GET "/accounts/${acct}/cfd_tunnel?name=${1}&is_deleted=false" | jq -r '.[0].id // empty'
}

# Create a remotely-managed tunnel; print its id.
tunnel_create() {
  local acct; acct="$(account_id)"
  local body; body="$(jq -nc --arg n "$1" '{name:$n, config_src:"cloudflare"}')"
  api POST "/accounts/${acct}/cfd_tunnel" "$body" | jq -r '.id'
}

# Print the run token for a tunnel id.
tunnel_token() {
  local acct; acct="$(account_id)"
  api GET "/accounts/${acct}/cfd_tunnel/${1}/token" | jq -r '.'
}

# Print a tunnel's ingress as hostname<TAB>service lines (catch-all excluded).
# Locally-managed tunnels (or freshly-created ones) have no remote config; that
# returns API error 1055, which we treat as "no ingress" rather than failing.
tunnel_pairs() {
  local acct resp; acct="$(account_id)"
  resp="$(cf_raw GET "/accounts/${acct}/cfd_tunnel/${1}/configurations")"
  [[ "$(jq -r '.success // false' <<<"$resp")" == "true" ]] || return 0
  jq -r '(.result.config.ingress // [])[] | select(.hostname) | [.hostname, .service] | @tsv' <<<"$resp"
}

# Replace a tunnel's ingress config from hostname<TAB>service lines on stdin.
put_config() {
  local acct tid="$1"; acct="$(account_id)"
  local rules='[]' h s
  while IFS=$'\t' read -r h s; do
    [[ -n "$h" ]] || continue
    rules="$(jq -c --arg h "$h" --arg s "$s" '. + [{hostname:$h, service:$s}]' <<<"$rules")"
  done
  local body; body="$(jq -nc --argjson r "$rules" '{config:{ingress: ($r + [{service:"http_status:404"}])}}')"
  api PUT "/accounts/${acct}/cfd_tunnel/${tid}/configurations" "$body" >/dev/null
}

# Drop one hostname from a tunnel's ingress and push the result.
# `grep || true` guards against grep exiting 1 when it filters out every line
# (removing the last subdomain) — which under set -e + pipefail would abort.
config_drop_host() {
  local tid="$1" hostname="$2"
  tunnel_pairs "$tid" | { grep -v "^${hostname}"$'\t' || true; } | put_config "$tid"
}

# Upsert a proxied CNAME hostname -> <tid>.cfargotunnel.com.
dns_upsert() {
  local zone hostname="$1" tid="$2"; zone="$(zone_id)"
  local content="${tid}.cfargotunnel.com"
  local recid; recid="$(api GET "/zones/${zone}/dns_records?type=CNAME&name=${hostname}" | jq -r '.[0].id // empty')"
  local body; body="$(jq -nc --arg n "$hostname" --arg c "$content" '{type:"CNAME", name:$n, content:$c, proxied:true}')"
  if [[ -n "$recid" ]]; then api PUT "/zones/${zone}/dns_records/${recid}" "$body" >/dev/null
  else api POST "/zones/${zone}/dns_records" "$body" >/dev/null; fi
}

dns_delete() {
  local zone hostname="$1"; zone="$(zone_id)"
  local recid; recid="$(api GET "/zones/${zone}/dns_records?type=CNAME&name=${hostname}" | jq -r '.[0].id // empty')"
  if [[ -n "$recid" ]]; then
    api DELETE "/zones/${zone}/dns_records/${recid}" >/dev/null
    ok "Deleted DNS CNAME for ${hostname}"
  else
    warn "No CNAME for ${hostname} (already gone?)."
  fi
}

# Find the tunnel (other than $2) whose ingress already maps $1; print "id<TAB>name".
hostname_owner() {
  local hostname="$1" exclude="$2" acct id name; acct="$(account_id)"
  while IFS=$'\t' read -r id name; do
    [[ -z "$id" || "$id" == "$exclude" ]] && continue
    if tunnel_pairs "$id" | grep -q "^${hostname}"$'\t'; then
      printf '%s\t%s\n' "$id" "$name"; return 0
    fi
  done < <(api GET "/accounts/${acct}/cfd_tunnel?is_deleted=false" | jq -r '.[] | [.id, .name] | @tsv')
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
action_create() {
  [[ -n "$NAME" ]]          || die "create requires a name: create <name> --map sub=service"
  [[ "${#MAPS[@]}" -gt 0 ]] || die "create requires --map sub=service[,sub=service...]"

  local tid; tid="$(tunnel_id "$NAME")"
  if [[ -z "$tid" ]]; then
    info "Creating tunnel '${NAME}'..."
    tid="$(tunnel_create "$NAME")"
    ok "Created tunnel '${NAME}' (id ${tid})"
  else
    info "Using existing tunnel '${NAME}' (id ${tid})"
  fi

  # Seed desired pairs from the tunnel's current ingress.
  declare -A want=()
  local h s
  while IFS=$'\t' read -r h s; do [[ -n "$h" ]] && want["$h"]="$s"; done < <(tunnel_pairs "$tid")

  local entry sub svc hostname owner oid oname
  for entry in "${MAPS[@]}"; do
    [[ "$entry" == *=* ]] || die "Bad mapping '$entry' (expected sub=service)"
    sub="${entry%%=*}"; svc="$(normalize_service "${entry#*=}")"
    hostname="${sub}.${DOMAIN}"

    owner="$(hostname_owner "$hostname" "$tid")"
    if [[ -n "$owner" ]]; then
      oid="${owner%%$'\t'*}"; oname="${owner#*$'\t'}"
      if confirm "${hostname} already belongs to tunnel '${oname}'. Move it to '${NAME}'?"; then
        config_drop_host "$oid" "$hostname"   # rewrite other tunnel without this host
        ok "Moved ${hostname} out of tunnel '${oname}'"
      else
        warn "Skipping ${hostname} (left in tunnel '${oname}')."
        continue
      fi
    fi
    want["$hostname"]="$svc"
  done

  # Push ingress config, then route DNS for each hostname. Every subdomain on
  # this tunnel shares the same CNAME target, so report it once and tick off
  # each host as its (serial) DNS call completes.
  { for h in "${!want[@]}"; do printf '%s\t%s\n' "$h" "${want[$h]}"; done; } | sort | put_config "$tid"
  ok "Updated ingress config for '${NAME}'"
  info "Routing DNS -> ${tid}.cfargotunnel.com"
  local n=0 total="${#want[@]}"
  while IFS= read -r h; do
    n=$((n+1))
    printf '    [%d/%d] %s' "$n" "$total" "$h"
    dns_upsert "$h" "$tid"
    printf ' %s✓%s\n' "$C_OK" "$C_RST"
  done < <(printf '%s\n' "${!want[@]}" | sort)

  echo
  ok "Tunnel '${NAME}' ready with ${#want[@]} subdomain(s)."
  action_show "$NAME"
  info "Start it with:  $0 up ${NAME}"
}

pidfile() { echo "${RUN_DIR}/${1}.pid"; }
logfile() { echo "${RUN_DIR}/${1}.log"; }

# If a backgrounded tunnel <name> is alive, print its pid and return 0.
# Cleans up a stale pid file otherwise.
is_running() {
  local pf pid; pf="$(pidfile "$1")"
  [[ -f "$pf" ]] || return 1
  pid="$(cat "$pf" 2>/dev/null)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then echo "$pid"; return 0; fi
  rm -f "$pf"; return 1
}

action_up() {
  [[ -n "$NAME" ]] || die "up requires a name: up <name>"
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared not found (needed to run the tunnel)."
  local tid; tid="$(tunnel_id "$NAME")"
  [[ -n "$tid" ]] || die "No tunnel named '${NAME}'. Run: $0 create ${NAME} --map sub=service"
  local token; token="$(tunnel_token "$tid")"

  # Token goes via TUNNEL_TOKEN env (not --token) so it won't appear in `ps`.
  if [[ "$BACKGROUND" -eq 1 ]]; then
    mkdir -p "$RUN_DIR"
    local pid; if pid="$(is_running "$NAME")"; then die "'${NAME}' is already running (pid ${pid})."; fi
    local lf; lf="$(logfile "$NAME")"
    TUNNEL_TOKEN="$token" nohup cloudflared tunnel run </dev/null >"$lf" 2>&1 &
    pid=$!
    echo "$pid" > "$(pidfile "$NAME")"
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$(pidfile "$NAME")"
      warn "Process exited immediately. Last log lines:"; tail -n 15 "$lf" >&2
      die "Failed to start '${NAME}'."
    fi
    ok "Started '${NAME}' in background (pid ${pid})."
    info "Logs: $0 logs ${NAME}    Stop: $0 stop ${NAME}"
  else
    info "Running tunnel '${NAME}' (id ${tid}). Ctrl+C to stop."
    exec env TUNNEL_TOKEN="$token" cloudflared tunnel run
  fi
}

action_stop() {
  [[ -n "$NAME" ]] || die "stop requires a name: stop <name>"
  local pid
  if pid="$(is_running "$NAME")"; then
    kill "$pid" 2>/dev/null || true
    local i; for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then warn "Forcing stop..."; kill -9 "$pid" 2>/dev/null || true; fi
    rm -f "$(pidfile "$NAME")"
    ok "Stopped '${NAME}' (pid ${pid})."
  else
    warn "'${NAME}' is not running."
  fi
}

action_status() {
  mkdir -p "$RUN_DIR"
  local pid
  if [[ -n "$NAME" ]]; then
    if pid="$(is_running "$NAME")"; then ok "${NAME}: running (pid ${pid})"; else info "${NAME}: stopped"; fi
    return
  fi
  local pf name any=0
  shopt -s nullglob
  for pf in "$RUN_DIR"/*.pid; do
    name="$(basename "$pf" .pid)"; any=1
    if pid="$(is_running "$name")"; then printf '  %srunning%s  %s (pid %s)\n' "$C_OK" "$C_RST" "$name" "$pid"
    else printf '  %sstopped%s  %s\n' "$C_WRN" "$C_RST" "$name"; fi
  done
  shopt -u nullglob
  [[ "$any" -eq 1 ]] || info "No background tunnels."
}

action_logs() {
  [[ -n "$NAME" ]] || die "logs requires a name: logs <name>"
  local lf; lf="$(logfile "$NAME")"
  [[ -f "$lf" ]] || die "No log for '${NAME}' at ${lf}."
  if [[ "$FOLLOW" -eq 1 ]]; then exec tail -n 40 -f "$lf"; else tail -n 40 "$lf"; fi
}

action_remove() {
  [[ -n "$NAME" ]] || die "remove requires a name: remove <name> -s <sub>"
  local hostname; hostname="$(resolve_hostname)"
  [[ -n "$hostname" ]] || die "remove requires --subdomain or --hostname"
  local tid; tid="$(tunnel_id "$NAME")"
  [[ -n "$tid" ]] || die "No tunnel named '${NAME}'."

  if tunnel_pairs "$tid" | grep -q "^${hostname}"$'\t'; then
    config_drop_host "$tid" "$hostname"
    ok "Removed ${hostname} from tunnel '${NAME}'"
  else
    warn "No mapping for ${hostname} in tunnel '${NAME}'."
  fi
  dns_delete "$hostname"
}

action_destroy() {
  [[ -n "$NAME" ]] || die "destroy requires a name: destroy <name>"
  local acct tid; acct="$(account_id)"; tid="$(tunnel_id "$NAME")"
  [[ -n "$tid" ]] || { warn "No tunnel named '${NAME}'."; return 0; }

  local -a hosts=(); local h
  while IFS=$'\t' read -r h _; do [[ -n "$h" ]] && hosts+=("$h"); done < <(tunnel_pairs "$tid")

  confirm "Destroy tunnel '${NAME}', its config, and ${#hosts[@]} subdomain(s)?" || { info "Aborted."; return 0; }

  # Stop any backgrounded instance and clean its pid/log files.
  local rpid
  if rpid="$(is_running "$NAME")"; then
    info "Stopping backgrounded '${NAME}' (pid ${rpid})..."
    kill "$rpid" 2>/dev/null || true
  fi
  rm -f "$(pidfile "$NAME")" "$(logfile "$NAME")"

  info "Deleting DNS records..."
  for h in "${hosts[@]}"; do dns_delete "$h"; done

  info "Cleaning up tunnel connections..."
  api DELETE "/accounts/${acct}/cfd_tunnel/${tid}/connections" >/dev/null 2>&1 || true
  info "Deleting tunnel '${NAME}'..."
  api DELETE "/accounts/${acct}/cfd_tunnel/${tid}" >/dev/null
  ok "Deleted tunnel '${NAME}'"
}

show_one() {
  local tid="$1" name="$2"
  printf '%sTunnel%s %s  (id: %s)\n' "$C_INF" "$C_RST" "$name" "$tid"
  local any=0 h s
  while IFS=$'\t' read -r h s; do
    [[ -n "$h" ]] || continue
    printf '    %s -> %s\n' "$h" "$s"; any=1
  done < <(tunnel_pairs "$tid")
  [[ "$any" -eq 1 ]] || printf '    (no subdomains)\n'
}

action_show() {
  local name="${1:-$NAME}" acct; acct="$(account_id)"
  if [[ -n "$name" ]]; then
    local tid; tid="$(tunnel_id "$name")"
    [[ -n "$tid" ]] || { warn "No tunnel named '${name}'."; return 0; }
    show_one "$tid" "$name"
  else
    local id n found=0
    while IFS=$'\t' read -r id n; do
      [[ -z "$id" ]] && continue
      show_one "$id" "$n"; found=1
    done < <(api GET "/accounts/${acct}/cfd_tunnel?is_deleted=false" | jq -r '.[] | [.id, .name] | @tsv')
    [[ "$found" -eq 1 ]] || info "No tunnels in this account."
  fi
}

action_list() {
  local acct; acct="$(account_id)"
  printf '%-38s %s\n' "ID" "NAME"
  api GET "/accounts/${acct}/cfd_tunnel?is_deleted=false" \
    | jq -r '.[] | [.id, .name] | @tsv' \
    | while IFS=$'\t' read -r id n; do printf '%-38s %s\n' "$id" "$n"; done
}

# Save an API token to the config (after verifying it). `auth` prompts hidden;
# `auth <token>` takes it as an argument.
action_auth() {
  local tok="${NAME:-}"
  if [[ -z "$tok" ]]; then read -r -s -p "Cloudflare API token: " tok; echo; fi
  [[ -n "$tok" ]] || die "No token provided."
  local resp; resp="$(curl -sS "${API}/user/tokens/verify" -H "Authorization: Bearer ${tok}")" \
    || die "Network error verifying token."
  [[ "$(jq -r '.success // false' <<<"$resp")" == "true" ]] \
    || die "Token invalid: $(jq -rc '.errors' <<<"$resp")"
  config_set token "$tok"
  chmod 600 "$CONFIG_FILE"
  ok "Token saved to ${CONFIG_FILE} (chmod 600)."
  warn "It is stored in PLAINTEXT — keep this file private. The env var CLOUDFLARE_API_TOKEN overrides it."
}

# Show/set the default domain. `domain` re-picks; `domain <name>` sets directly.
action_domain() {
  if [[ -n "$NAME" ]]; then
    api GET "/zones?name=${NAME}" | jq -e '.[0]' >/dev/null 2>&1 \
      || die "Zone '${NAME}' is not visible to this token."
    config_set domain "$NAME"
    ok "Default domain set to ${NAME} (saved in ${CONFIG_FILE})"
  else
    local cur; cur="$(config_get domain)"
    [[ -n "$cur" ]] && info "Current default domain: ${cur}"
    pick_domain
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  case "$ACTION" in
    # _fetch_zone runs in the parent shell so _ACCT/_ZONE are cached for the
    # action's subshell calls (otherwise each $(account_id) re-hits /zones).
    create)         preflight; ensure_domain; _fetch_zone; action_create ;;
    up)             preflight; ensure_domain; _fetch_zone; action_up ;;
    remove|rm)      preflight; ensure_domain; _fetch_zone; action_remove ;;
    destroy)        preflight; ensure_domain; _fetch_zone; action_destroy ;;
    show)           preflight; ensure_domain; _fetch_zone; action_show ;;
    list)           preflight; ensure_domain; _fetch_zone; action_list ;;
    domain)         preflight; action_domain ;;
    auth|login)     preflight_tools; action_auth ;;
    stop|down)      action_stop ;;
    status|ps)      action_status ;;
    logs)           action_logs ;;
    -h|--help|help) usage ;;
    *)              die "Unknown action: '$ACTION' (expected create|up|remove|destroy|show|list|domain|auth|stop|status|logs)" ;;
  esac
}

main "$@"
