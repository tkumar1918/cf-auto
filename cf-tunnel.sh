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
VERSION="1.5.1"
RAW_BASE="https://raw.githubusercontent.com/tkumar1918/cf-auto"
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
PRUNE=0              # 1 when create/apply should remove unlisted subdomains
declare -a MAPS=()

_ACCT=""              # memoized account id
_ZONES_LOADED=0       # 1 once zones have been fetched
declare -A ZONE_ID=() # zone name -> id (every zone the token can see)

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
                    Example: create web --map app=3000,api=8002
  apply <file>      Provision every tunnel in a JSON spec (declarative). See below.
  up <name> [-d]    Run the tunnel (foreground). With -d/--background, run
                    detached (writes pid + log under ~/.config/cf-tunnel/run).
  install <name>    Install a systemd --user service so the tunnel auto-starts.
  uninstall <name>  Stop and remove the systemd --user service.
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
  update [ref]      Update cf-tunnel in place (default: latest release; or a tag/branch).
  version           Print the version (also: -V, --version).

Spec file (apply): JSON of the form
  { "domain": "example.com",
    "tunnels": { "web": { "app": "3000", "api": "8002" }, "shop": { "store": "4000" } } }

Multiple domains (same account): a mapping key that already ends in one of your
zones is used as a full hostname; a bare label gets the default domain. So one
tunnel can span domains, e.g. --map app.foo.com=3000,api.bar.com=8002. Needs a
token scoped to those zones (Zone Resources: all zones, or each one).

Options:
  -m, --map <sub=service[,...]>  Mappings for create, comma-separated. The key is
                             a bare label (uses the default domain) or a full
                             hostname under any visible zone. Service shorthand:
                             app=3000            -> http://localhost:3000
                             app=localhost:3000  -> http://localhost:3000
                             app=http://h:3000   -> as-is
  -s, --subdomain <sub>    Subdomain label                      (remove)
      --hostname <fqdn>    Full hostname (overrides subdomain)  (remove)
      --domain <domain>    Zone/apex domain (overrides saved default)
  -d, --background         Run detached                         (up)
  -f, --follow             Follow the log (tail -f)             (logs)
      --prune              Remove subdomains not in the spec    (apply, create)
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
      --prune)         PRUNE=1; shift ;;
      -y|--yes)        ASSUME_YES=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      -V|--version)    echo "cf-tunnel ${VERSION}"; exit 0 ;;
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

# ---------------------------------------------------------------------------
# Config store (~/.config/cf-tunnel/config)
# ---------------------------------------------------------------------------
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

# Fetch every zone the token can see (name -> id) and the account id, once.
# (Deriving the account from a zone avoids needing account-list permission.)
_fetch_zones() {
  [[ "$_ZONES_LOADED" -eq 1 ]] && return
  local z name id; z="$(api GET "/zones?per_page=50")"
  while IFS=$'\t' read -r name id; do
    [[ -n "$name" ]] && ZONE_ID["$name"]="$id"
  done < <(jq -r '.[] | [.name, .id] | @tsv' <<<"$z")
  [[ "${#ZONE_ID[@]}" -gt 0 ]] || die "This token can't see any zones (needs Zone>Read)."
  _ACCT="${CLOUDFLARE_ACCOUNT_ID:-$(jq -r '.[0].account.id // empty' <<<"$z")}"
  [[ -n "$_ACCT" ]] || die "Could not determine account id. Set CLOUDFLARE_ACCOUNT_ID."
  _ZONES_LOADED=1
}
account_id() { _fetch_zones; echo "$_ACCT"; }

# Print the zone id that owns a hostname (longest matching zone-name suffix).
zone_for_host() {
  _fetch_zones
  local host="$1" name best=""
  for name in "${!ZONE_ID[@]}"; do
    if [[ "$host" == "$name" || "$host" == *".${name}" ]]; then
      [[ "${#name}" -gt "${#best}" ]] && best="$name"
    fi
  done
  [[ -n "$best" ]] || die "No visible zone owns hostname '${host}'."
  echo "${ZONE_ID[$best]}"
}

# Resolve a mapping key to a full hostname: a key already ending in a visible
# zone is used as-is (any domain); otherwise the default domain is appended.
map_hostname() {
  _fetch_zones
  local key="$1" name
  for name in "${!ZONE_ID[@]}"; do
    [[ "$key" == "$name" || "$key" == *".${name}" ]] && { echo "$key"; return; }
  done
  echo "${key}.${DOMAIN}"
}

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
  local hostname="$1" tid="$2" zone; zone="$(zone_for_host "$hostname")"
  local content="${tid}.cfargotunnel.com"
  local recid; recid="$(api GET "/zones/${zone}/dns_records?type=CNAME&name=${hostname}" | jq -r '.[0].id // empty')"
  local body; body="$(jq -nc --arg n "$hostname" --arg c "$content" '{type:"CNAME", name:$n, content:$c, proxied:true}')"
  if [[ -n "$recid" ]]; then api PUT "/zones/${zone}/dns_records/${recid}" "$body" >/dev/null
  else api POST "/zones/${zone}/dns_records" "$body" >/dev/null; fi
}

# Delete the CNAME for a hostname (no-op with a note if it doesn't exist).
dns_delete() {
  local hostname="$1" zone; zone="$(zone_for_host "$hostname")"
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
# Ensure tunnel NAME exists and serves the mappings in MAPS (create-or-update
# ingress + route DNS). Shared by `create` and `apply`.
provision_tunnel() {
  [[ -n "$NAME" ]]          || die "a tunnel name is required"
  [[ "${#MAPS[@]}" -gt 0 ]] || die "at least one sub=service mapping is required"

  local tid; tid="$(tunnel_id "$NAME")"
  if [[ -z "$tid" ]]; then
    info "Creating tunnel '${NAME}'..."
    tid="$(tunnel_create "$NAME")"
    ok "Created tunnel '${NAME}' (id ${tid})"
  else
    info "Using existing tunnel '${NAME}' (id ${tid})"
  fi

  # Snapshot current ingress. The desired set keeps the existing subdomains,
  # except under --prune, which makes the tunnel match exactly the given maps.
  declare -A current=() want=()
  local h s
  while IFS=$'\t' read -r h s; do [[ -n "$h" ]] && current["$h"]="$s"; done < <(tunnel_pairs "$tid")
  if [[ "$PRUNE" -ne 1 ]]; then
    for h in "${!current[@]}"; do want["$h"]="${current[$h]}"; done
  fi

  local entry key svc hostname owner oid oname
  for entry in "${MAPS[@]}"; do
    [[ "$entry" == *=* ]] || die "Bad mapping '$entry' (expected sub=service)"
    key="${entry%%=*}"; svc="$(normalize_service "${entry#*=}")"
    hostname="$(map_hostname "$key")"

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

  # --prune: drop DNS for subdomains that were present but are no longer desired
  # (their ingress entries are already gone, since put_config wrote only `want`).
  if [[ "$PRUNE" -eq 1 ]]; then
    for h in "${!current[@]}"; do
      [[ -n "${want[$h]+x}" ]] && continue
      info "Pruning ${h}"
      dns_delete "$h"
    done
  fi
  ok "Tunnel '${NAME}' ready with ${#want[@]} subdomain(s)."
}

action_create() {
  provision_tunnel
  action_show "$NAME"
  info "Start it with:  $0 up ${NAME}"
}

# Apply a JSON spec, provisioning each tunnel to match it. Schema:
#   { "domain": "example.com",          # optional, overrides the default
#     "tunnels": { "web": { "app": "3000", "api": "8002" }, ... } }
action_apply() {
  local file="$NAME"
  [[ -n "$file" ]] || die "apply requires a spec file: apply <file.json>"
  [[ -f "$file" ]] || die "Spec file not found: ${file}"
  jq empty "$file" 2>/dev/null || die "Spec is not valid JSON: ${file}"

  local d; d="$(jq -r '.domain // empty' "$file")"
  if [[ -n "$d" ]]; then DOMAIN="$d"; DOMAIN_EXPLICIT=1; fi
  ensure_domain
  _fetch_zones

  local names; names="$(jq -r '.tunnels // {} | keys[]' "$file")"
  [[ -n "$names" ]] || die "Spec has no tunnels."
  local t sub svc
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    info "── Applying tunnel '${t}' ──"
    NAME="$t"; MAPS=()
    while IFS=$'\t' read -r sub svc; do [[ -n "$sub" ]] && MAPS+=("${sub}=${svc}"); done \
      < <(jq -r --arg t "$t" '.tunnels[$t] | to_entries[] | "\(.key)\t\(.value)"' "$file")
    if [[ "${#MAPS[@]}" -eq 0 ]]; then warn "Tunnel '${t}' has no mappings; skipping."; continue; fi
    provision_tunnel
  done <<< "$names"
  echo
  ok "Applied $(jq -r '.tunnels | length' "$file") tunnel(s) from ${file}."
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

# Re-download the script over itself from GitHub. With no ref, use the latest
# release tag (immediate + stable); `update main` tracks the bleeding edge.
# Uses `mv` so the running process keeps its old inode until it exits.
action_update() {
  local ref="${NAME:-}"
  if [[ -z "$ref" ]]; then
    ref="$(curl -fsSL "https://api.github.com/repos/tkumar1918/cf-auto/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')"
    [[ -n "$ref" ]] || ref="main"
  fi
  local target="$0"
  [[ "$target" != /* ]] && target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
  [[ -w "$target" ]] || die "Cannot write ${target} (re-run the installer, or use sudo)."
  info "Updating ${target} (from ${ref})..."
  local tmp; tmp="$(mktemp)"
  curl -fsSL "${RAW_BASE}/${ref}/cf-tunnel.sh" -o "$tmp" || { rm -f "$tmp"; die "Download failed."; }
  head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash' || { rm -f "$tmp"; die "Downloaded file doesn't look like cf-tunnel."; }
  chmod +x "$tmp"; mv -f "$tmp" "$target"
  ok "Updated to $("$target" --version 2>/dev/null || echo "$ref")."
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
# systemd boot persistence (Linux, --user services)
# ---------------------------------------------------------------------------
# Absolute path to this command, for the service's ExecStart.
self_path() {
  if command -v cf-tunnel >/dev/null 2>&1; then command -v cf-tunnel; return; fi
  local p="$0"; [[ "$p" != /* ]] && p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  echo "$p"
}
unit_dir()  { echo "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; }
unit_name() { echo "cf-tunnel-${1}.service"; }

# Generate, enable, and start a systemd --user service for a tunnel.
action_install() {
  [[ -n "$NAME" ]] || die "install requires a name: install <name>"
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found; 'install' needs Linux + systemd."
  [[ -n "$(config_get token)" ]] || die "Save your token first (the service can't read your shell env): $0 auth <token>"
  local tid; tid="$(tunnel_id "$NAME")"
  [[ -n "$tid" ]] || die "No tunnel named '${NAME}'. Create it first."

  local dir bin uf; dir="$(unit_dir)"; mkdir -p "$dir"
  bin="$(self_path)"; uf="${dir}/$(unit_name "$NAME")"
  cat > "$uf" <<EOF
[Unit]
Description=cf-tunnel: ${NAME}
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${bin} up ${NAME}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  ok "Wrote ${uf}"
  systemctl --user daemon-reload
  systemctl --user enable --now "$(unit_name "$NAME")"
  ok "Service cf-tunnel-${NAME} enabled and started."
  info "Status: systemctl --user status cf-tunnel-${NAME}"
  info "Logs:   journalctl --user -u cf-tunnel-${NAME} -f"
  info "To run without an active login (boot persistence): sudo loginctl enable-linger ${USER}"
}

# Stop, disable, and remove a tunnel's systemd --user service.
action_uninstall() {
  [[ -n "$NAME" ]] || die "uninstall requires a name: uninstall <name>"
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found."
  systemctl --user disable --now "$(unit_name "$NAME")" 2>/dev/null || true
  rm -f "$(unit_dir)/$(unit_name "$NAME")"
  systemctl --user daemon-reload 2>/dev/null || true
  ok "Removed service cf-tunnel-${NAME}."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  case "$ACTION" in
    # _fetch_zones runs in the parent shell so _ACCT/ZONE_ID are cached for the
    # action's subshell calls (otherwise each $(account_id) re-hits /zones).
    create)         preflight; ensure_domain; _fetch_zones; action_create ;;
    apply)          preflight; action_apply ;;
    up)             preflight; ensure_domain; _fetch_zones; action_up ;;
    remove|rm)      preflight; ensure_domain; _fetch_zones; action_remove ;;
    destroy)        preflight; ensure_domain; _fetch_zones; action_destroy ;;
    show)           preflight; ensure_domain; _fetch_zones; action_show ;;
    list)           preflight; ensure_domain; _fetch_zones; action_list ;;
    domain)         preflight; action_domain ;;
    auth|login)     preflight_tools; action_auth ;;
    install)        preflight; ensure_domain; _fetch_zones; action_install ;;
    uninstall)      action_uninstall ;;
    stop|down)      action_stop ;;
    status|ps)      action_status ;;
    logs)           action_logs ;;
    update)         preflight_tools; action_update ;;
    version|--version|-V) echo "cf-tunnel ${VERSION}" ;;
    -h|--help|help) usage ;;
    *)              die "Unknown action: '$ACTION' (expected create|apply|up|remove|destroy|show|list|domain|auth|install|uninstall|stop|status|logs|update|version)" ;;
  esac
}

main "$@"
