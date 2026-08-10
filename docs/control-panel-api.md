# Control panel API contract

Replit's QueenSync control panel drives Kannaktopus over the public NATS
swarm bus. This document is the contract for what subjects to publish to
and what payloads to send. Pair with [observatory-presence.md](observatory-presence.md)
which covers the read-side (how Kannaktopus shows up on the observatory).

## Architecture

```
┌──────────────────────────┐   KANNAKTOPUS.command.<arm_id>   ┌───────────────────────────────┐
│ QueenSync control panel  │ ────────────────────────────────►│ scripts/kannaktopus_listener.py│
│ (Replit)                 │   reply on _INBOX.*              │ subscribes + dispatches        │
│                          │ ◄────────────────────────────────│ to local handlers              │
│                          │                                  └───────────────────────────────┘
│                          │   queen.event.join (every 30s)   ┌───────────────────────────────┐
│                          │ ◄────────────────────────────────│ scripts/queensync_presence.py │
│                          │   QUEEN.phase.<arm_id> (per work)│ orchestrate.sh phase pulses   │
│                          │ ◄────────────────────────────────│ via lib/nats-publish.sh       │
└──────────────────────────┘                                  └───────────────────────────────┘
```

## Command channel

### Subjects

| Subject                              | Purpose                                              | Anon publish? |
| ------------------------------------ | ---------------------------------------------------- | ------------- |
| `KANNAKA.ask.<arm_id>`               | **Recommended** for the Replit Console — anon-publishable per the bus's ADR-0026 ACL. | ✅            |
| `KANNAKA.ask.broadcast`              | Anon-publishable fan-out to every arm. **Every** arm replies — collect them, don't `nc.request()`; see [Broadcast](#broadcast-collecting-every-arms-reply). | ✅            |
| `KANNAKTOPUS.command.<arm_id>`       | Internal / authenticated — same handlers, kannaka_internal-only publish. | ❌            |
| `KANNAKTOPUS.command.broadcast`      | Internal / authenticated fan-out. Same collection pattern as above. | ❌            |

The Replit control panel should use the `KANNAKA.ask.*` subjects so it
can connect to the bus without holding `kannaka_internal` credentials —
the bus allows anonymous publish on `KANNAKA.ask.>` and anonymous
subscribe on `_INBOX.>`, which is enough for the standard NATS
request-reply pattern. The same listener handles all four subjects
identically; no per-subject behavior differences.

### Request schema

```json
{
  "cmd": "<command-name>",
  "args": { "...": "command-specific" }
}
```

### Reply schema

The listener replies on whatever NATS reply inbox the request carried (the
standard request-reply pattern). Every reply carries the canonical
constellation envelope — `schema_version`, `ts`, `agent_id` — the same one
`queensync_presence.py` publishes. Both shapes are valid:

```json
{ "schema_version": "1.0", "ts": 1786399670083, "agent_id": "kannaktopus-01",
  "ok": true,  "result": { "...": "..." } }

{ "schema_version": "1.0", "ts": 1786399670084, "agent_id": "kannaktopus-01",
  "ok": false, "error": "<message>" }
```

| Field            | Type              | Notes                                                        |
| ---------------- | ----------------- | ------------------------------------------------------------ |
| `schema_version` | string            | Spec version string, currently `"1.0"` — not a bare `"1"`.   |
| `ts`             | integer           | Unix **milliseconds**, not seconds and not ISO-8601.          |
| `agent_id`       | string            | The replying arm's `KANNAKTOPUS_ARM_ID`.                      |

The envelope is on **every** reply, including the `unknown_command` and
`json_decode` errors — there is no reply shape that arrives unattributed.

`agent_id` is what makes broadcast replies usable: see
[Broadcast: collecting every arm's reply](#broadcast-collecting-every-arms-reply).

### Supported commands

| `cmd`           | Args                                          | Result                                                                                       |
| --------------- | --------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `ping`          | none                                          | `{pong: true, arm_id, ts}` — liveness probe.                                                 |
| `status`        | none                                          | `{arm_id, mcp_listen_port, orchestrate_path, orchestrate_available, kannaka_bin_available, platform}`. `mcp_listen_port` is the port the MCP HTTP server actually binds (`HTTP_PORT`, or an explicit `KANNAKTOPUS_MCP_PORT` override) and is `null` when no HTTP listener is configured — clients must handle null. `orchestrate_path` is the resolved absolute path, or `null`. |
| `capabilities`  | none                                          | `{capabilities: [...], skills: [...]}` — for rendering quick-action buttons. `skills` is discovered from `skills/<dir>/SKILL.md` and identified by the **frontmatter `name`**, never the directory basename; a skill whose frontmatter has no `name` is skipped rather than guessed at. The result is cached and re-read only when a `SKILL.md` mtime changes. |
| `version`       | none                                          | `{kannaktopus, python, nats_py}`.                                                            |
| `wake`          | `{[reason]}`                                  | `{awake: true, arm_id, ts, status: {…}}` — wake-from-idle handshake for the Console; pairs with `KANNAKTOPUS_WAKE_URL`. Always succeeds (Kannaktopus is always-on while systemd is enabled). |
| `run`           | `{skill, prompt, [timeout_seconds]}`          | **RESERVED / deliberately deferred** ([#32](https://github.com/NickFlach/Kannaktopus/issues/32)) — returns `{implemented: false, status: "deferred", tracking_issue, note}`. Not an unfinished stub: executing skills from this handler table would expose remote code execution over the anon-publishable `KANNAKA.ask.broadcast` subject, so the bus ACLs, an invocable-command allowlist, timeouts and bounded output capture have to be settled first. |

Unknown commands reply with `{ok: false, error: "unknown_command: ...", supported: [...]}`.

## Example: ping from the control panel

Using the `nats` CLI to mock what the panel will do:

```bash
nats --server nats://swarm.ninja-portal.com:4222 \
  req KANNAKTOPUS.command.kannaktopus-01 \
  '{"cmd":"ping"}'
# {"schema_version": "1.0", "ts": 1746432000123, "agent_id": "kannaktopus-01",
#  "ok": true, "result": {"pong": true, "arm_id": "kannaktopus-01", "ts": 1746432000.123}}
```

## Addressing one arm: `nc.request()`

The **direct** subjects (`KANNAKA.ask.<arm_id>`,
`KANNAKTOPUS.command.<arm_id>`) have exactly one responder, so plain
request/reply is the right pattern and nothing about it has changed:

```ts
import { connect, JSONCodec } from "nats";

const nc = await connect({ servers: "nats://swarm.ninja-portal.com:4222" });
const codec = JSONCodec();

const reply = await nc.request(
  "KANNAKTOPUS.command.kannaktopus-01",
  codec.encode({ cmd: "status" }),
  { timeout: 5000 },
);
console.log(codec.decode(reply.data)); // { schema_version, ts, agent_id, ok, result }
```

## Broadcast: collecting every arm's reply

**Do not use `nc.request()` on the `*.broadcast` subjects.** Request/reply is
structurally single-response: NATS delivers your request to every subscribed
arm and every arm replies into your inbox, but `nc.request()` resolves with
the first reply and discards the rest. On a bus with N arms you observe 1
reply and silently lose N−1.

Use scatter-gather instead — subscribe to your own inbox, publish with that
inbox as the reply subject, and collect until a deadline. This needs no extra
bus grants: anonymous clients may already publish on `KANNAKA.ask.>` and
subscribe on `_INBOX.>`, which is exactly what this pattern uses.

```ts
import { connect, JSONCodec, createInbox } from "nats";

const nc = await connect({ servers: "nats://swarm.ninja-portal.com:4222" });
const codec = JSONCodec();

async function scatterGather(subject, payload, windowMs = 2000) {
  const inbox = createInbox();               // "_INBOX.<random>"
  const sub = nc.subscribe(inbox);
  nc.publish(subject, codec.encode(payload), { reply: inbox });

  const byArm = new Map();
  const deadline = Date.now() + windowMs;
  (async () => {
    for await (const m of sub) {
      const reply = codec.decode(m.data);
      byArm.set(reply.agent_id, reply);       // agent_id is what disambiguates
      if (Date.now() >= deadline) break;
    }
  })();

  await new Promise((r) => setTimeout(r, windowMs));
  sub.unsubscribe();
  return [...byArm.values()];
}

const replies = await scatterGather("KANNAKA.ask.broadcast", { cmd: "status" });
console.log(`${replies.length} arms answered:`, replies.map((r) => r.agent_id));
```

Notes for implementers:

- **`agent_id` is the correlation key.** All replies land in one inbox; the
  envelope's `agent_id` is what makes them individually observable. Key
  results by it (as above) so a duplicate reply from one arm cannot be
  mistaken for a second arm.
- **A broadcast result is inherently partial.** There is no arm census on the
  bus, so "how many *should* have answered" is not knowable from the client.
  Render what came back within the window and say how many that was — do not
  present it as a complete fleet view. For aggregate cross-arm state, the
  observatory is the right surface; it already aggregates.
- **Pick the window from the slowest command you send.** `ping` and
  `capabilities` are local and fast; a 1–2 s window is generous.
- **Late replies are discarded**, not applied, because the subscription is
  torn down at the deadline. If you need to match late arrivals rather than
  drop them, add your own `correlation_id` to the request `args` — the
  listener echoes `args` back only for `run` today, so treat cross-request
  correlation as client-side state keyed on the inbox you created.

## Authentication

**Listener side** (Kannaktopus): authenticates as `kannaka_internal` so it
can subscribe to the `KANNAKTOPUS.command.>` subjects. Credentials resolve in
this order:

1. `NATS_USER` + `NATS_PASSWORD` from the environment
2. `NATS_CREDS` (path to an nkey/JWT credentials file) from the environment
3. the same keys parsed out of **`~/.kannaka-nats.env`** — the file the
   constellation crons and systemd launchers already source. `export `
   prefixes, quotes and `#` comments are tolerated; values are never logged.
   Override the path with `KANNAKTOPUS_CREDS_FILE`.

**The listener fails closed.** If nothing resolves and the subject set
includes the authenticated-only `KANNAKTOPUS.command.*` subjects, it exits
non-zero **before connecting**, naming the expected credentials path — rather
than joining anonymously and going silently deaf on every command subject it
was deployed to serve:

```
$ python scripts/kannaktopus_listener.py
kannaktopus_listener: refusing to start — no NATS credentials resolved, but the
subject set includes KANNAKTOPUS.command.* which the constellation bus restricts
to authenticated users. ...
  Expected credentials file: /home/opc/.kannaka-nats.env
$ echo $?
3
```

Operationally this means a host with missing credentials produces a systemd
**restart loop** rather than a healthy-looking, half-deaf daemon. That is the
intended trade — put the credentials in place (or an `EnvironmentFile=`, see
`scripts/systemd/kannaktopus-listener.service`) before enabling the unit.

**Anon-only listener** (the legitimate case): `KANNAKA.ask.>` is
anon-publishable by design, so an operator may deliberately run a listener
with no credentials. Opt in explicitly and it binds only the subjects it can
actually serve:

```bash
python scripts/kannaktopus_listener.py --anon-only
# or: KANNAKTOPUS_ANON_ONLY=1 python scripts/kannaktopus_listener.py
# → subscribed to 2/2 subjects (KANNAKA.ask.<arm_id>, KANNAKA.ask.broadcast)
```

What no longer exists is the silent middle ground where the listener connects
anonymously while still claiming the four-subject set.

**Replit control panel side**: connect anonymously and use the
`KANNAKA.ask.<arm_id>` subjects. No credentials required.

```
KANNAKTOPUS_WAKE_URL=nats://swarm.ninja-portal.com:4222
```

(That's the public TCP endpoint of the constellation NATS bus. The
Console's Node server uses [`nats.js`](https://github.com/nats-io/nats.js)
as the client. No auth params needed; default user is `anon`.)

If the constellation operators ever tighten the anon ACL on
`KANNAKA.ask.>`, the Console will need to set `NATS_USER` /
`NATS_PASSWORD` env vars too — single change, no redesign.

## HTTP observatory API (local)

Separate from the NATS command channel, the MCP server can expose a small
read-only HTTP API for the observatory when `HTTP_PORT` is set (it serves
`/api/hrm/*` — `status`, `observe`, `constellation`, `recall`, `clusters`,
`neighbors`, `traverse`). This surface shells out to the local `kannaka`
binary, so it must not be reachable by untrusted clients.

Authentication is controlled by the `OCTO_HTTP_TOKEN` env var:

| `OCTO_HTTP_TOKEN` | Bind address      | Auth requirement                                   |
| ----------------- | ----------------- | -------------------------------------------------- |
| **set**           | all interfaces    | every `/api/*` request must send `Authorization: Bearer <token>`; otherwise `401`. |
| **unset**         | `127.0.0.1` only  | no token gate — the server is only reachable from the local host, and a startup warning is logged. |

The token comparison is constant-time. Set a token whenever the port is
exposed beyond the local host:

```bash
OCTO_HTTP_TOKEN="$(openssl rand -hex 32)" HTTP_PORT=8787 node mcp-server/dist/index.js

curl -s http://<host>:8787/api/hrm/status \
  -H "Authorization: Bearer $OCTO_HTTP_TOKEN"
```

## Versioning policy

The `cmd` strings are stable. New commands are additive — old ones won't
disappear without an explicit deprecation window. Args within a command
may grow new optional fields; required fields will not change.

The `run` command shape is **reserved** and its implementation is a
documented deferral, not an oversight ([#32](https://github.com/NickFlach/Kannaktopus/issues/32)).
Its args may evolve before it ships. Treat any `run`-shaped contract as draft
until `implemented: true` is in the reply.

The reply envelope (`schema_version`, `ts`, `agent_id`) is additive to the
`{ok, result}` / `{ok, error}` shapes that were there before — existing
clients that read only `ok`/`result` keep working unchanged.

## Deployment

### Listener (run somewhere always-on, e.g. Oracle)

```bash
pip install nats-py

# credentials must resolve first — see Authentication above
python scripts/kannaktopus_listener.py

# ...or, for an anon-only listener serving KANNAKA.ask.* only:
python scripts/kannaktopus_listener.py --anon-only
```

Or as a systemd service:

```bash
sudo cp scripts/systemd/kannaktopus-listener.service \
        /etc/systemd/system/kannaktopus-listener.service
sudo systemctl daemon-reload
sudo systemctl enable --now kannaktopus-listener.service
```

### Pair with the presence daemon

For the full bidirectional control surface, run **both** the presence
beacon and the command listener:

```bash
sudo systemctl enable --now \
  kannaktopus-presence.service \
  kannaktopus-listener.service
```

The presence daemon makes the arm visible on the observatory; the
listener makes it controllable.
