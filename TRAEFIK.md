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

Persistent state: `/var/lib/traefik/acme.json` on the /var disk survives
image rebuilds.

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

## Files

| File | Perm | Purpose |
|------|------|---------|
| `machines/<name>/traefik/traefik.yml`       | 0644 | Static config |
| `machines/<name>/traefik/dynamic/*.yml`     | 0644 | Dynamic rules (file provider) |
| `machines/<name>/acme-dns.env`              | 0600 | `ACME_DNS_API_BASE` + `ACME_DNS_STORAGE_PATH` for the lego acmedns provider |
| `machines/<name>/acme-dns.json`             | 0600 | Per-domain acme-dns credentials (managed by `just acme-register`) |
