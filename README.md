# cf-tunnel.sh

A single bash script to manage Cloudflare tunnels with **one API token** — no
`cloudflared tunnel login`, no `cert.pem`, no per-tunnel config files on disk.
Tunnels, routing, and DNS all live at Cloudflare and are driven through the API.
`cloudflared` is only needed to *run* a tunnel.

## Model

    one tunnel = many subdomains

- A tunnel is created **remotely-managed** (`config_src: cloudflare`), so its
  ingress rules are stored at Cloudflare, not on disk.
- One tunnel serves many subdomains. Each subdomain has its own DNS CNAME, all
  pointing at that tunnel's `<id>.cfargotunnel.com`.
- A subdomain is unique: its CNAME points at exactly one tunnel. The service it
  forwards to can be reused freely (many subdomains may target the same port).

The only things kept on the machine are a small settings file (your token + the
default domain) and, for backgrounded tunnels, pid/log files — all under
`~/.config/cf-tunnel/`.

## Requirements

- `jq` and `curl` (for the API calls)
- `cloudflared` (only to run a tunnel via `up`)
- A domain already on Cloudflare
- An API token (see below)

## API token

One token does everything. Create it at
https://dash.cloudflare.com/profile/api-tokens using **Create Custom Token** with
these three permissions:

| Type    | Group             | Access |
| ------- | ----------------- | ------ |
| Account | Cloudflare Tunnel | Edit   |
| Zone    | DNS               | Edit   |
| Zone    | Zone              | Read   |

- Under **Account Resources**, include your account.
- Under **Zone Resources**, include the zone(s) you want to manage — one zone for
  least privilege, or all zones if you manage multiple domains.

Note: the prebuilt "Edit zone DNS" template is **not enough** — it lacks the
`Account > Cloudflare Tunnel > Edit` permission. Use a custom token.

Provide the token either way:

    export CLOUDFLARE_API_TOKEN=<token>     # env var, takes precedence
    ./cf-tunnel.sh auth <token>             # saved to config (verified, chmod 600)

`auth` with no argument prompts for the token (hidden input). The saved token
lives in `~/.config/cf-tunnel/config` in **plaintext** (file mode 600) — the env
var overrides it when set.

Optional: `export CLOUDFLARE_ACCOUNT_ID=<id>`. Otherwise the account id is derived
from the zone, so you usually don't need it.

## Default domain

The first command that needs a domain picks one from the zones your token can see
and saves it as the default in `~/.config/cf-tunnel/config`:

- one zone visible -> chosen automatically
- multiple zones -> you're prompted to choose

Change it anytime, or override per-command:

    ./cf-tunnel.sh domain                # show current, re-pick
    ./cf-tunnel.sh domain example.com    # set directly (must be visible to token)
    ./cf-tunnel.sh create myapp --map x=3000 --domain example.com   # one-off override

## Multiple domains

One account can hold many domains, and the script manages them all:

- Account-wide commands (`list`, `show`, `destroy`, `up`, `install`) already span
  every tunnel, regardless of domain.
- Per-domain commands (`create`, `apply`, `remove`) target a domain via the bare
  key + default domain, or by using a **full hostname** as the mapping key. A key
  ending in one of your visible zones is used as-is; otherwise the default domain
  is appended. So one tunnel can serve subdomains across domains:

      cf-tunnel create gw --map app.foo.com=3000,api.bar.com=8002

  In an `apply` spec, mapping keys may likewise be full hostnames spanning domains.

Requirement: the token must be scoped to those zones — **Zone Resources → All
zones**, or list each zone. A single-zone token only manages that one domain.

## Install

Install it as a global `cf-tunnel` command. The installer downloads the latest
script onto your PATH **and auto-installs missing dependencies** (`jq` and
`cloudflared`) into the same directory:

    curl -fsSL https://raw.githubusercontent.com/tkumar1918/cf-auto/main/install.sh | bash

Then use it from anywhere:

    cf-tunnel --help

The installer tracks the latest (`main`) by default. Use `SKIP_DEPS=1` to skip
dependency install, `PREFIX=/path/bin` to choose the directory, and `REF` to pin
a version:

    REF=v1.5.0 curl -fsSL https://raw.githubusercontent.com/tkumar1918/cf-auto/v1.5.0/install.sh | bash

Manual alternative:

    curl -fsSL https://raw.githubusercontent.com/tkumar1918/cf-auto/main/cf-tunnel.sh \
      -o ~/.local/bin/cf-tunnel && chmod +x ~/.local/bin/cf-tunnel

Or clone the repo and run `./cf-tunnel.sh` directly.

## Updating

    cf-tunnel update           # rewrite the installed script with the latest (main)
    cf-tunnel update v1.5.0    # or pin a specific release/branch/tag
    cf-tunnel version          # show the installed version (also -V / --version)

`update` re-downloads the script over itself in place (equivalent to re-running
the installer). It uses an atomic replace, so it's safe to run while a tunnel is
running.

## Commands

    cf-tunnel.sh <action> <name> [options]

| Action                                  | Description                                                                |
| --------------------------------------- | -------------------------------------------------------------------------- |
| `create <name> --map sub=service[,...]` | Create/update the tunnel, set its ingress config, route each subdomain's DNS. Idempotent. |
| `apply <file>`                          | Provision every tunnel in a JSON spec (declarative). See below.            |
| `up <name> [-d]`                        | Run the tunnel (foreground). `-d`/`--background` runs it detached.          |
| `install <name>`                        | Install a systemd `--user` service so the tunnel auto-starts on boot.       |
| `uninstall <name>`                      | Stop and remove the systemd `--user` service.                              |
| `stop <name>`                           | Stop a backgrounded tunnel.                                                |
| `status [name]`                         | Show running/stopped state of backgrounded tunnels.                        |
| `logs <name> [-f]`                      | Show a backgrounded tunnel's log (`-f` to follow).                         |
| `remove <name> -s <sub>`                | Remove one subdomain: its ingress entry and its DNS CNAME.                 |
| `destroy <name>`                        | Delete the whole tunnel, its DNS records, and its config.                 |
| `show [name]`                           | Show one tunnel, or every tunnel, and its subdomains.                       |
| `list`                                  | List all tunnels in the account.                                           |
| `domain [name]`                         | Show/choose the default domain (saved for future runs).                    |
| `auth [token]`                          | Save an API token to the config (verified; prompts if omitted).            |

## Options

| Option                          | Applies to      | Meaning                                            |
| ------------------------------- | --------------- | -------------------------------------------------- |
| `-m, --map <sub=service[,...]>` | create          | Subdomain-to-service mappings, comma-separated.    |
| `-s, --subdomain <sub>`         | remove          | Subdomain label, e.g. `app`.                       |
| `--hostname <fqdn>`             | remove          | Full hostname, overrides `--subdomain`.            |
| `--domain <domain>`             | create, remove  | Zone/apex domain (overrides the saved default).    |
| `-d, --background`              | up              | Run detached.                                      |
| `-f, --follow`                  | logs            | Follow the log (`tail -f`).                        |
| `--prune`                       | apply, create   | Remove subdomains not in the spec (exact match).   |
| `-y, --yes`                     | create, destroy | Don't prompt (auto-confirm conflict moves/destroy).|
| `-h, --help`                    | any             | Show usage.                                        |

### Passing mappings

A mapping is `sub=service`. Pass them with `--map`, comma-separated:

    ./cf-tunnel.sh create myapp --map app=3000,api=8002,shop=4000

The key is normally a bare label (gets the default domain). It can also be a full
hostname under any zone your token can see — see [Multiple domains](#multiple-domains).

### Service shorthand

| You write              | Becomes                  |
| ---------------------- | ------------------------ |
| `app=3000`             | `http://localhost:3000`  |
| `app=localhost:3000`   | `http://localhost:3000`  |
| `app=192.168.1.5:8080` | `http://192.168.1.5:8080`|
| `app=http://host:3000` | `http://host:3000` (kept as-is) |

## Examples

    export CLOUDFLARE_API_TOKEN=<token>      # or: ./cf-tunnel.sh auth <token>

    ./cf-tunnel.sh create myapp --map app=3000,api=8002   # create + route
    ./cf-tunnel.sh up myapp                               # run (foreground)
    ./cf-tunnel.sh up myapp -d                            # run detached
    ./cf-tunnel.sh status                                 # what's running
    ./cf-tunnel.sh logs myapp -f                          # follow its log
    ./cf-tunnel.sh stop myapp                             # stop the detached run
    ./cf-tunnel.sh create myapp --map shop=4000           # add a subdomain
    ./cf-tunnel.sh remove myapp -s api                    # drop one subdomain
    ./cf-tunnel.sh show                                   # all tunnels
    ./cf-tunnel.sh list
    ./cf-tunnel.sh destroy myapp                          # tear it down

## Conflicts (subdomain already on another tunnel)

A subdomain's CNAME can point at only one tunnel, so the same subdomain can't be
on two tunnels. If you map one that already belongs to another tunnel, the script
prompts:

    app.example.com already belongs to tunnel 'web'. Move it to 'api'? [y/N]

- `y` removes it from the old tunnel's config and re-points its DNS to the new one.
- `n` skips that mapping.
- `-y/--yes` auto-confirms.

Duplicate *services* are fine: `app=3000` and `dashboard=3000` (different
subdomains, same port) both work. The backend distinguishes them by the `Host`
header, which cloudflared forwards as the public hostname.

## Declarative apply

Describe all your tunnels and their subdomains in one JSON file and apply it:

    cf-tunnel apply tunnels.json

```json
{
  "domain": "example.com",
  "tunnels": {
    "web":  { "app": "3000", "api": "8002" },
    "shop": { "store": "4000" }
  }
}
```

Each tunnel is created-or-updated to include its mappings (same idempotent logic
as `create`), and DNS is routed for every subdomain. `domain` is optional and
overrides the default for that run. Use `-y` to auto-confirm conflict moves.

By default apply is **additive** — it never removes anything. Add `--prune` to
make each listed tunnel match its spec exactly: subdomains on those tunnels that
aren't in the JSON are removed (ingress + their DNS). Tunnels not listed in the
JSON are always left untouched, with or without `--prune`.

    cf-tunnel apply tunnels.json --prune

See [examples/tunnels.json](examples/tunnels.json).

## Boot persistence (systemd)

`up -d` doesn't survive a reboot. To auto-start a tunnel on boot, install it as a
systemd `--user` service (Linux, no root):

    cf-tunnel auth <token>       # save the token first (the service reads the config)
    cf-tunnel install myapp      # write + enable + start the service
    cf-tunnel uninstall myapp    # stop + remove it

Manage it with the usual systemd tools:

    systemctl --user status cf-tunnel-myapp
    journalctl --user -u cf-tunnel-myapp -f

To keep user services running without an active login (true boot persistence),
enable lingering once:

    sudo loginctl enable-linger "$USER"

## Background tunnels

`up -d` runs a tunnel detached (via `nohup`), writing pid and log files under
`~/.config/cf-tunnel/run/<name>.{pid,log}`:

    ./cf-tunnel.sh up myapp -d        # start detached
    ./cf-tunnel.sh status             # list running/stopped
    ./cf-tunnel.sh logs myapp -f      # follow the log
    ./cf-tunnel.sh stop myapp         # stop it

The run token is passed via the `TUNNEL_TOKEN` env var, so it does not appear in
`ps`. `destroy` also stops a backgrounded instance and removes its run files.

This is a lightweight, no-root approach (survives terminal close, not reboot).
For boot persistence, use `cf-tunnel install` (see above).

## How it works (API)

| Step              | Endpoint                                                            |
| ----------------- | ------------------------------------------------------------------- |
| Resolve account   | derived from `GET /zones?name=<domain>` -> `.account.id`            |
| Create tunnel     | `POST /accounts/{acct}/cfd_tunnel` `{name, config_src:"cloudflare"}`|
| Set ingress       | `PUT /accounts/{acct}/cfd_tunnel/{id}/configurations`               |
| Route / clean DNS | `POST` / `PUT` / `DELETE /zones/{zone}/dns_records` (proxied CNAME) |
| Run               | `GET .../{id}/token`, then `cloudflared tunnel run` with `TUNNEL_TOKEN` |
| Destroy           | delete DNS, `DELETE .../{id}/connections`, `DELETE .../{id}`        |

## Notes

- `up` (foreground) is one process per tunnel; `up -d` backgrounds it. Run several
  tunnels by starting several.
- Multiple tunnels run concurrently with no port conflict: the local service
  binds the port; cloudflared connects out to it.
- `localhost` in a mapping is relative to the machine running that tunnel.
- `show`/`list` need network access (state lives at Cloudflare).

## License

MIT — see [LICENSE](LICENSE).
