# Traefik

Reverse proxy driven by a single per-VM config directory in the machine dir.
Standard Traefik YAML — the profile does not wrap Traefik's config surface.

- Static config:   `machines/<name>/traefik/traefik.yml`
- Dynamic config:  `machines/<name>/traefik/dynamic/*.yml` (file provider, hot-reloaded)

On the VM:

| Mode | Path |
|------|------|
| immutable / semi-mutable KVM | `/var/identity/traefik/` |
| mutable KVM, proxmox-lxc     | `/etc/traefik/`         |

Missing `traefik.yml` → the systemd unit's `ConditionPathExists` fails and
traefik silently no-ops at boot.

## Preconditions

- `traefik` added to `machines/<name>/profile`.
- TCP 80 and 443 are already in the default `tcp_ports` seed.

## 1. Create the VM

```bash
just create <name> core,traefik
```

Seeds `machines/<name>/traefik/traefik.yml` with commented examples
(entrypoints, providers.file, dashboard, ACME certresolvers),
`dynamic/example.yml.disabled` (rename to `*.yml` to activate), and
`machines/<name>/acme-dns.env` (populated later by `just acme-register`).

## 2. Configure

Edit `machines/<name>/traefik/traefik.yml`. References:

- Static config: <https://doc.traefik.io/traefik/reference/install-configuration/introduction/>
- Dynamic file provider: <https://doc.traefik.io/traefik/reference/dynamic-configuration/file/>

Router / service / middleware definitions go under
`machines/<name>/traefik/dynamic/*.yml`.

## 3. Apply

```bash
just sync-identity <name>
```

Stages the whole machine dir onto the VM (including `traefik/` and
`acme-dns.{env,json}`) and restarts services. Dynamic files
(`dynamic/*.yml`) are hot-reloaded by Traefik itself, so you can also
`scp` them into `/var/identity/traefik/dynamic/` (or `/etc/traefik/dynamic/`
on mutable/LXC) on the running VM if you don't want to stop it.

## 4. Verify

```bash
ssh admin@<name> systemctl status traefik
curl -I http://<vm-ip>/
```

## ACME certs via acme-dns

Traefik's built-in ACME client obtains certs from Let's Encrypt using the
`dnsChallenge` provider `acmedns`. Per-domain credentials live in
`machines/<name>/acme-dns.json`; the acme-dns server URL lives in
`machines/<name>/acme-dns.env`. The traefik profile mounts that env file
as an `EnvironmentFile=-` on the systemd unit (non-fatal if absent).

Persistent state is `/var/lib/traefik/acme.json`. Whether it survives
`just recreate` depends on the VM mode:

- **Immutable / semi-mutable KVM**: /var is a separate disk. Certs survive
  `just upgrade` and `just recreate`.
- **Mutable KVM / LXC**: /var lives on the rootfs. Certs are destroyed by
  `just recreate`. On LXC, add a `mounts` line so `/var/lib/traefik` is
  bind-mounted from a host ZFS dataset that outlives the container:

  ```
  # machines/<name>/mounts
  rust/traefik-<name>:/var/lib/traefik
  ```

  The dataset is auto-created on first `just create`. See
  [MODES.md](MODES.md) for the full rebuild-vs-recreate matrix.

### Preconditions

- An acme-dns server you control (self-hosted or public), reachable from
  both the VM and the workstation.
- DNS control of every domain you'll cert (to publish `CNAME` records at
  `_acme-challenge.<domain>`).
- Traefik VM reachable on port 443 from the internet (or your clients);
  DNS-01 does not require inbound port 80.

### First-time setup

1. Register a wildcard covering every host you plan to serve under one zone
   (one CNAME, one cert, unlimited subdomains):
   ```bash
   just acme-register <vm> '*.nas.example.com'
   ```
   First run prompts for the acme-dns server URL and writes it to
   `machines/<vm>/acme-dns.env`. Subsequent runs read it from the env file.

2. Publish the CNAME record the helper prints, at your authoritative
   nameserver:
   ```
   _acme-challenge.nas.example.com.  CNAME  <uuid>.acme-dns.example.com.
   ```

3. Verify the CNAME resolves:
   ```bash
   just acme-verify <vm> '*.nas.example.com'
   ```

4. Uncomment the `certificatesResolvers.letsencrypt` block in
   `machines/<vm>/traefik/traefik.yml` and set `email:`:
   ```yaml
   certificatesResolvers:
     letsencrypt:
       acme:
         email: you@example.com
         storage: /var/lib/traefik/acme.json
         dnsChallenge:
           provider: acmedns
   ```

5. Add a router in `machines/<vm>/traefik/dynamic/*.yml` that references
   `certResolver: letsencrypt` and pins the wildcard via `tls.domains`
   (otherwise Traefik would try to obtain a per-Host cert and lego
   wouldn't find matching acme-dns credentials). See the seeded
   `dynamic/example.yml.disabled`:
   ```yaml
   tls:
     certResolver: letsencrypt
     domains:
       - main: "*.nas.example.com"
   ```

6. Push everything to the VM:
   ```bash
   just sync-identity <vm>
   ```

Traefik obtains the certificate on the next request routed to a matching
Host, or within a few seconds of restart if the router already exists at
boot. `journalctl -u traefik -f` on the VM shows issuance progress.

### Adding a Host under an existing wildcard

Just add a new router to `dynamic/*.yml` with `tls.domains` still pointing
at the same wildcard. The cert already covers it — no new registration,
no new CNAME. `just sync-identity <vm>` to push.

### Registering a second wildcard (different zone)

Repeat steps 1–3 with the new wildcard. Add a router referencing it
via `tls.domains: [{main: "*.other-zone.com"}]`. `just sync-identity`.

### Renewal

Automatic, ~30 days before expiry. No reload needed — Traefik holds
certs in memory and swaps them without dropping connections.

## Listen only on WireGuard

Combine with the [`wireguard`](WIREGUARD.md) profile and bind Traefik to the
tunnel IP:

```yaml
entryPoints:
  web:
    address: "10.0.0.1:80"
```

The traefik profile sets `net.ipv4.ip_nonlocal_bind = 1`, so this bind
succeeds even before wg0 is up at boot. Traffic still has to pass the
`wg-input` chain in `wireguard.nft` — add an accept rule for tcp dport 80/443
for the peers you want to serve.

## Peer identity injection (wg-auth)

When the `traefik` and `wireguard` profiles are both enabled, the traefik
profile ships two forward-auth middlewares that map a request's source IP
to a pre-authenticated user identity via an `X-Remote-User` header:

- **`wg-user`** — attach `X-Remote-User: <user>` when the source IP is a
  wg peer listed in `wg_users`. Unmapped peers pass through with no
  identity asserted (the backend does its own auth).
- **`wg-required`** — same, but return 403 for unmapped peers. Use for
  peers-only routes.

Both fail closed: if the auth service or map is unavailable, requests
5xx rather than silently forward. If the generator fails validation, the
middleware definitions aren't emitted and routers referencing them 404.

### 1. Map peers to users

Edit `machines/<name>/wg_users` (seeded as a commented template by
`just create`):

```
# <wg-peer>  <user>
laptop       alice
phone        alice
guest-pc     bob
```

Peer names come from the `# hostname:` comments above each `[Peer]`
block in `wireguard.conf`. Multiple peers may map to the same user.

### 2. Attach to a router

In your `traefik/dynamic/*.yml`:

```yaml
http:
  routers:
    myapp:
      rule: "Host(`myapp.example.com`)"
      entryPoints: [websecure]
      middlewares: [wg-required]        # or [wg-user]
      service: myapp
      tls: {certResolver: letsencrypt}
```

The copyparty example seeded by the `nas` profile uses `wg-required` (see
`machines/<name>/traefik/dynamic/example.yml.disabled`). It also includes a
higher-priority `copyparty-block-zfs` router that matches any URL containing
`/.zfs/` and applies the `block-all` middleware — a reusable "reject with
403" primitive provisioned in `middleware-block-all.yml` (always active,
seeded alongside the example). Attach `middlewares: [block-all]` to a
higher-priority `PathRegexp` router to hard-block any URL pattern.

The `copyparty-block-zfs` router is defense-in-depth on top of the
container-side `.zfs` mask (see [Automatic `.zfs` masking](PROXMOX_LXC.md#automatic-zfs-masking)
in the LXC docs); direct-URL lookups are already blocked at the filesystem
layer, and the traefik router closes the same gap at the edge.

### Restricting to specific users

`wg-required` accepts any mapped peer — network-level allowlist. To also
filter on the identified user (e.g. only `ryan` can reach the syncthing
GUI, even though other peers are mapped), pass `?users=<comma-list>` to
`/require` via a custom middleware. Define one alongside your router:

```yaml
http:
  middlewares:
    # Peer must be mapped AND its user must be ryan.
    wg-required-ryan:
      chain:
        middlewares: [wg-strip-user, wg-auth-require-ryan]
    wg-auth-require-ryan:
      forwardAuth:
        address: "http://127.0.0.1:9099/require?users=ryan"
        authResponseHeaders: [X-Remote-User]
  routers:
    myapp:
      # …
      middlewares: [wg-required-ryan]
```

The `?users=` list is an allowlist — a mapped peer whose user isn't listed
gets 403, same posture as an unmapped peer. Empty / absent (`/require`
alone) accepts any mapped user, which is what the shipped `wg-required`
does. The same parameter works on `/lookup` — a mapped-but-not-allowed
user just passes through with no `X-Remote-User` header.

Reuse `wg-strip-user` from the shipped set to clear any client-supplied
`X-Remote-User` before the auth step. Define one such middleware per
user-scope you need (e.g. `wg-required-ryan`, `wg-required-family`); the
router picks whichever fits.

### 3. Apply

```bash
just sync-identity <name>
# then, inside a mutable / LXC VM:
sudo nixos-rebuild switch --flake /etc/nixos
# — or for immutable KVM:
just upgrade <name>
```

### 4. Verify

Inside the VM:

```bash
curl -sS http://127.0.0.1:9099/healthz
# → "ok"

sudo cat /run/wg-auth/users.map
# ip <TAB> user rows, one per mapped device

curl -sSD - -H 'X-Forwarded-For: 10.0.0.5' http://127.0.0.1:9099/lookup
# → 200 OK
# → X-Remote-User: alice   (when 10.0.0.5 is mapped)
```

End-to-end, from a mapped wg peer:

```bash
curl https://myapp.example.com/
```

The backend service must trust the header. Copyparty is auto-configured
by the `nas` profile (`idp-h-usr: x-remote-user`, `auth-ord: idp`). Other
common backends support this as "reverse-proxy header auth" — e.g.
Grafana's `auth.proxy`, Gitea's `REVERSE_PROXY_AUTHENTICATION_HEADER`.

### Files added by this feature

| File | Perm | Purpose |
|------|------|---------|
| `machines/<name>/wg_users`            | 0644 | wg peer → user mapping (source of truth) |
| `/run/wg-auth/users.map`              | 0640 | IP → user map (generated) |
| `/etc/traefik/dynamic/wg-users.yml`   | 0644 | Middleware definitions (generated). `/var/identity/traefik/dynamic/` on immutable. |

## Files

| File | Perm | Purpose |
|------|------|---------|
| `machines/<name>/traefik/traefik.yml`       | 0644 | Static config |
| `machines/<name>/traefik/dynamic/*.yml`     | 0644 | Dynamic rules (file provider) |
| `machines/<name>/traefik/dynamic/middleware-block-all.yml` | 0644 | Reusable "reject with 403" middleware (`block-all`). Seeded once; edit or delete to change the primitive. |
| `machines/<name>/traefik/dynamic/example.yml.disabled`     | 0644 | Reference example (copyparty router + `copyparty-block-zfs`). **Overwritten on every `seed-config`.** Rename to `example.yml` to activate — your renamed copy is untouched. |
| `machines/<name>/acme-dns.env`              | 0600 | `ACME_DNS_API_BASE` + `ACME_DNS_STORAGE_PATH` for the lego acmedns provider |
| `machines/<name>/acme-dns.json`             | 0600 | Per-domain acme-dns credentials (managed by `just acme-register`) |
| `machines/<name>/wg_users`                  | 0644 | wg peer → user mapping consumed by wg-auth (see [Peer identity injection](#peer-identity-injection-wg-auth)) |
