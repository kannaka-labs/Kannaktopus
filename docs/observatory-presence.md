# Observatory presence

Kannaktopus participates in the Kannaka Constellation by publishing a
periodic "I am alive" message on the public NATS swarm bus. Once the
presence beacon is running, this Kannaktopus instance shows up as an
agent on
[observatory.ninja-portal.com](https://observatory.ninja-portal.com)
and the matching `kannaktopus_arm` card on the QueenSync Queen Console
flips from `offline` to `idle`.

## Architecture

```
Kannaktopus host                                Kannaka constellation
┌────────────────────────────────┐              ┌───────────────────────────┐
│ scripts/queensync_presence.py  │  publishes   │ swarm.ninja-portal.com    │
│   every 30s →                  │ ───────────► │ NATS :4222                │
│     queen.event.join           │              │  ├─► observatory swarm    │
│                                │              │  │    /api/state agents{} │
│ scripts/orchestrate.sh         │  per phase   │  └─► QueenSync NATS bridge│
│   QUEEN.phase.<armId>          │ ───────────► │       arm card heartbeat  │
│   (probe/grasp/tangle/ink)     │              │                           │
└────────────────────────────────┘              └───────────────────────────┘
```

QueenSync's bridge treats every `queen.event.join` as a heartbeat for the
named arm. The 3-minute staleness sweep demotes the card back to `offline`
if joins stop arriving, so a 30-second interval gives plenty of headroom.

## Prerequisites

| Requirement                       | Why                                                                 |
| --------------------------------- | ------------------------------------------------------------------- |
| Outbound TCP to `:4222`           | The bus has no inbound flow; everything is publish.                 |
| `pip install nats-py`             | Used by `scripts/queensync_presence.py`.                            |
| (optional) `nats` CLI on `PATH`   | Lets `orchestrate.sh` emit `QUEEN.phase.*` events via `nats-publish.sh`. |

The public bus is read-only-ish: no auth is required to **publish** join
events for your own arm id, but the constellation operators reserve the
right to drop noisy publishers. Keep the interval ≥ 30s.

### Credentials

Once the bus tightens its anon ACL, `queen.event.*` and `QUEEN.phase.*`
publishes from an unauthenticated client are **rejected silently** — no
error, no log line, the arm simply never appears. Set `NATS_USER` and
`NATS_PASSWORD` (or, for the `nats` CLI path, `NATS_CREDS=/path/to.creds`)
to authenticate.

On a systemd host, put them in `/etc/kannaktopus/nats.env`:

```bash
sudo install -d -m 0700 /etc/kannaktopus
sudo tee /etc/kannaktopus/nats.env >/dev/null <<'EOF'
NATS_USER=kannaka_internal
NATS_PASSWORD=...
EOF
sudo chmod 0600 /etc/kannaktopus/nats.env
```

then uncomment the `EnvironmentFile=/etc/kannaktopus/nats.env` hook in
`scripts/systemd/kannaktopus-presence.service` (the listener unit carries
the same hook). systemd reads the file as root before dropping to the
`kannaktopus` user, so `0600 root:root` is both sufficient and correct.
Never commit that file.

## Configuration

| Env var                          | Default                                  | Effect                                                     |
| -------------------------------- | ---------------------------------------- | ---------------------------------------------------------- |
| `NATS_URL`                       | `nats://swarm.ninja-portal.com:4222`     | Override to point at a private bus during dev. Wins over `KANNAKA_NATS_URL`. |
| `KANNAKA_NATS_URL`               | *(unset)*                                | Constellation-wide bus URL, honoured when `NATS_URL` is unset or empty. |
| `NATS_USER` / `NATS_PASSWORD`    | *(unset)*                                | Bus credentials. Both must be set; otherwise every publish goes out anon. |
| `NATS_CREDS`                     | *(unset)*                                | Path to an nkey/JWT credentials file. Used by the `nats` CLI path (`nats-publish.sh`) and preferred over user/password. |
| `KANNAKTOPUS_ARM_ID`             | `kannaktopus-01`                         | Becomes the agent key in `swarm.agents` and the QueenSync arm row. Use `kannaka-prime` to take over the existing seeded card. |
| `KANNAKTOPUS_DISPLAY_NAME`       | `Kannaktopus`                            | Label rendered in the Queen Console.                       |
| `KANNAKTOPUS_PRESENCE_SECONDS`   | `30`                                     | Beacon interval. Values below `10` are clamped to `10`; non-numeric values fall back to `30`. |
| `KANNAKTOPUS_LOG_LEVEL`          | `INFO`                                   | `DEBUG` to see every publish.                              |

## Running

### Foreground (dev)

```bash
pip install nats-py
python scripts/queensync_presence.py
```

You should see

```
INFO  kannaktopus.presence connected to NATS nats://swarm.ninja-portal.com:4222
INFO  kannaktopus.presence published initial queen.event.join for kannaktopus-01
```

### systemd (Linux host)

A unit file ships at `scripts/systemd/kannaktopus-presence.service`. It
runs as a dedicated unprivileged user (`kannaktopus`) — create it once,
adjust `WorkingDirectory=` and `ExecStart=` to match your install, then
enable the service:

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin kannaktopus
sudo cp scripts/systemd/kannaktopus-presence.service \
        /etc/systemd/system/kannaktopus-presence.service
sudo systemctl daemon-reload
sudo systemctl enable --now kannaktopus-presence.service
sudo journalctl -u kannaktopus-presence -f
```

The unit ships with `NoNewPrivileges`, `ProtectSystem=strict`,
`RestrictAddressFamilies=AF_INET AF_INET6`, and the rest of the standard
hardening flags — the daemon only needs outbound TCP to publish.

### Phase pulses (automatic)

`scripts/orchestrate.sh` sources `scripts/lib/nats-publish.sh` and emits
`QUEEN.phase.<armId>` on every embrace phase boundary
(`probe` → `grasp` → `tangle` → `ink`, plus `init` and `complete`). It also
fires a one-shot `queen.event.join` at workflow start so the arm appears
on the observatory immediately, before the long-running presence daemon
publishes its first beat.

These pulses are **fire-and-forget** — they background the publish and
silently no-op if the `nats` CLI is missing, so Kannaktopus never blocks
on the bus and never fails a workflow because of a network blip.

To enable, install the NATS CLI:

```bash
# Linux
curl -L https://github.com/nats-io/natscli/releases/latest/download/nats-$(uname -m)-linux.tar.gz | tar -xz
sudo install nats-*/nats /usr/local/bin/

# macOS
brew tap nats-io/nats-tools && brew install nats
```

Then run any embrace and watch the Queen Console: the kannaktopus_arm
card should pulse through the four phases in real time.

### Phase pulses (manual)

If you want Kannaktopus to *pulse* as it works (probe → grasp → tangle →
ink), source `scripts/lib/nats-publish.sh` from `orchestrate.sh` and call
`nats_publish_phase <phase> "<task_id>"` at each phase boundary. The
helper silently no-ops when the `nats` CLI isn't installed, so adding the
calls is safe even on hosts that don't want to publish.

## Verification

After the daemon has been running for ~30s:

```bash
# 1. The observatory shows you in its swarm map
curl -s https://observatory.ninja-portal.com/api/state \
  | jq '.swarm.agents | keys'
# expected: ["kannaka-01", "kannaktopus-01"]

# 2. (If you have access) The QueenSync arm card flipped to idle
curl -s https://console.ninja-portal.com/api/arms \
  | jq '.[] | select(.id=="kannaka-prime") | {status,lastHeartbeat}'
```

If the arm doesn't appear within ~60s, in order:

1. Confirm outbound TCP to `swarm.ninja-portal.com:4222` is allowed.
2. Run with `KANNAKTOPUS_LOG_LEVEL=DEBUG` and check that the connect log
   line prints.
3. Verify the subject name is exactly `queen.event.join` (typos here are
   silent — NATS will accept the publish but no one is subscribed).

## Stopping cleanly

`SIGTERM` / `SIGINT` triggers a final `queen.event.leave` publish and
then drains the connection. The Queen Console card flips to `offline`
immediately rather than waiting for the 3-minute staleness sweep.
