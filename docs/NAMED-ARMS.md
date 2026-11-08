# Named arms: Vigil and Ferryman

Kannaktopus has two named arms with standing jobs. Each one runs on its own model family, has a cost cap, and records every call in a ledger that can be graded later.

| Arm | Name | Job | Model | Default caps |
|---|---|---|---|---|
| `kannaka-vigil` | **Vigil**, the auditor | Tries to refute a document before it goes out under a lab name | GLM on OpenRouter (`z-ai/glm-5.3`), switchable to the local `kannaka-brain-glm-v1` LoRA | $0.10 per run, $2 per week |
| `kannaka-ferryman` (alias `kannaka-steward`) | **Ferryman**, the steward | Sweeps for leads, tracks deadlines and owed replies, proposes settlements, writes drafts for review | Claude on the Anthropic API (`claude-opus-5-5`) | $0.60 per run, $10 per week |

Vigil uses a model family different from the writers (kannaka-brain is on a Qwen base, the other writers on Claude). An auditor grading its own model family isn't independent, so a disagreement between families is the useful signal.

## What they cannot do

Each call is one HTTP request to a model API with no tools attached. Neither arm can send, post, pay, sign, register or resolve anything, because nothing it can reach does any of that. The limit is in the code path, not only in the prompt.

- Vigil returns verdicts. It never rewrites the author's text; for FIX it lists instructions.
- Ferryman writes drafts, register rows and proposed settlements to local files. Sending a draft, uploading a settlement and resolving a market are separate steps that Nick does.
- Ferryman's collectors are commands you configure in `~/.kannaktopus/config/arms/ferryman.json`. Each runs without a shell and under a timeout, and its stdout becomes one input. **"Read-only" is a convention of that file, not something the runner enforces**: Ferryman runs whatever `argv` the file holds. The file is Nick's; a collector must never mark mail as read, reply or post. `ferryman config` prints every collector's full argv so a change can be reviewed.

## Commands

```bash
# Vigil: exit 0 PUBLISH, 10 FIX, 11 DROP (3 = refused by a cap, 4 = bad reply, 5 = provider error)
scripts/orchestrate.sh vigil draft.md --source letter.pdf.txt --source https://example.org/report --kind essay
scripts/orchestrate.sh vigil draft.md --fetch-links          # also fetch up to 10 links in the file
scripts/orchestrate.sh vigil budget

# Ferryman
scripts/orchestrate.sh ferryman sweep --since 24h            # collectors → register + digest
scripts/orchestrate.sh ferryman due --days 7                 # from the register, no model call
scripts/orchestrate.sh ferryman settle --market 154 --evidence shareholder-letter.txt
scripts/orchestrate.sh ferryman draft brief.md --input thread.txt
scripts/orchestrate.sh ferryman budget

# As an ordinary arm (prompt in, reply out, still capped and ledgered)
scripts/orchestrate.sh spawn kannaka-vigil "Audit: ..."
OCTOPUS_FERRYMAN_TASK=sweep scripts/orchestrate.sh spawn kannaka-ferryman "<sweep payload>"
```

Ferryman has three tasks, so a spawn without `OCTOPUS_FERRYMAN_TASK` (sweep, settle or draft) is refused with exit 2 before any call. A generic prompt would otherwise be paid for and then fail the sweep schema. Prefer the `ferryman` subcommands.

Every command is also available directly as `python scripts/named_arms.py <command>` (standard library only, Python 3.9 or later).

Where things go:

| What | Path |
|---|---|
| Ledger (every call, 0600, append-only) | `~/.kannaktopus/ledger/instances/<arm>/answers.jsonl` |
| Vigil verdict JSON | `~/.kannaktopus/results/kannaka-vigil-<id>.json` |
| Sweep digest | `~/.kannaktopus/results/kannaka-ferryman-sweep-<id>.md` |
| Opportunity register (append-only, keyed by `id`) | `~/.kannaktopus/ferryman/register.jsonl` |
| Proposed settlements (each with Vigil's verdict, `approved_by_nick: false`) | `~/.kannaktopus/ferryman/settlements-pending.jsonl` |
| Drafts | `~/.kannaktopus/ferryman/drafts/<id>.md` |

## How Vigil audits

Vigil splits the document into atomic claims and marks each one:

- **SUPPORTED**: an input states it, quoted verbatim and cited as `source#locator`.
- **REFUTED**: an input contradicts it, quoted and cited.
- **UNVERIFIABLE**: no input settles it. This includes evidence about a nearby but different subject, such as another date or another product. Background knowledge never makes a claim SUPPORTED.

It flags invented first-person memories (rules-v2 rule MR) and gives an overall PUBLISH, FIX or DROP. The runner does not trust the reply; it checks it:

- A SUPPORTED or REFUTED claim that cites no provided input fails with exit 4.
- **The audited document is never evidence.** It is passed as an input so claims can be located, but a SUPPORTED or REFUTED claim whose only citations are the document itself fails with exit 4. A `--source` naming the document is dropped.
- **Every quote is checked against the input it cites**, after collapsing whitespace, normalising quote marks and dashes, dropping markdown `*` and backticks, and ignoring case; `...` may join pieces that occur in order. A SUPPORTED or REFUTED claim none of whose quotes is found is downgraded to UNVERIFIABLE (with a `runner_note`), and a PUBLISH that had one becomes FIX. In Ferryman's output, a sweep item or a YES/NO settlement with a quote that is not in its input fails with exit 4.
- A PUBLISH that carries a REFUTED claim fails with exit 4.

Each row records `quote_check` (per claim: `ok`, `partial`, `downgraded`, `self-cited` or `uncited`, with the reason for each evidence item), so the grader can count fabricated quotes. `content` stays the model's raw reply; `verdict_json` and the result file carry the runner's downgrades. The reply is kept in the ledger either way.

`ferryman settle` and `ferryman draft` run Vigil on their own output automatically. A draft counts as ready for Nick only after Vigil returns PUBLISH or FIX.

## Settlements

`ferryman settle` reads the public `markets.jsonl` from the Hugging Face dataset `Kannaka/calls-and-settlements`. It picks the rows with `outcome == null` and `settles_by` on or before today, or the one market named with `--market`. Without `--evidence` it lists what is due and what evidence each needs, and makes no model call. If the evidence does not state the deciding fact for the exact subject, date and threshold, the outcome is INCONCLUSIVE.

## Cost caps

Before every call the runner computes a worst case: input characters / 3 at the input price, plus `max_tokens` at the output price. It refuses the call (exit 3, no HTTP request) when:

- the worst case is over the per-run cap, or
- the spend over the last 7 days, summed from the arm's own ledger (`cost_usd`), plus the worst case is over the weekly cap, or
- the input is over `max_input_chars`.

Caps must be finite and not negative: `inf`, `nan` or `-1` in an env var or the config file exits 2. With Ferryman's server-side fallbacks on, the worst case is priced at the dearest Claude model in the table, because a rescued call bills at the fallback model's rates.

The weekly check and a reservation of the call's worst case happen in one locked step (an atomic-mkdir lock under `<ledger root>/.locks/`, reservations in `<ledger root>/.reservations/<arm>.json`), so parallel spawns see each other's in-flight spend instead of all passing the check at once. The reservation is released when the ledger row is written.

A refusal still writes a ledger row with `error="budget: ..."`, and so does an input that cannot be read or fetched. After a call, the real cost is recorded: OpenRouter's `usage.cost`, or the Anthropic token counts times the price table in `named_arms.py`. A call that failed after the request was sent (HTTP 5xx, a timeout, a dropped connection) may still be billed, so its row books the worst case with `cost_estimated: true`. If the real cost ever exceeds the pre-call worst case, the row says `cost_over_estimate: true` and a warning goes to stderr. Each call is also booked in the session usage log with role `actual`, so `orchestrate.sh cost` shows it.

OpenRouter requests carry `provider.max_price` from the price table (USD per million tokens), so OpenRouter refuses a route dearer than the estimate assumed, and `provider.data_collection: "deny"`, so no provider that keeps or trains on prompts is used. Both can be changed with `openrouter_provider` in `vigil.json`.

## Configuration

Defaults are in `scripts/named_arms.py`. A JSON file overrides them (copy `config/arms/vigil.example.json` or `config/arms/ferryman.example.json` to `~/.kannaktopus/config/arms/`), and environment variables override both:

| Variable | Meaning |
|---|---|
| `OCTOPUS_VIGIL_BACKEND` | `openrouter` (default) or `ollama`. `ollama` uses the local LoRA `kannaka-brain-glm-v1` at `$OLLAMA_HOST/v1`, which ollama and llama-server both serve |
| `OCTOPUS_VIGIL_MODEL`, `OCTOPUS_FERRYMAN_MODEL` | model id |
| `OCTOPUS_<ARM>_MAX_USD_RUN`, `OCTOPUS_<ARM>_MAX_USD_WEEK` | caps in USD |
| `OCTOPUS_<ARM>_MAX_TOKENS`, `OCTOPUS_<ARM>_BASE_URL`, `OCTOPUS_FERRYMAN_EFFORT` | request settings |
| `OCTOPUS_ARMS_LEDGER_ROOT` | ledger root (default `~/.kannaktopus/ledger`) |
| `OCTOPUS_NAMED_ARMS_NATS=true` | also pulse `QUEEN.phase.<arm>` with the verdict and cost (never content). Off by default |

Keys come only from the environment: `OPENROUTER_API_KEY` for Vigil, `ANTHROPIC_API_KEY` for Ferryman. The runner never reads a key file. Before sending and before logging, it masks these in prompts, inputs, replies and errors:

- anything shaped like a key: `sk-ant-` (admin keys included), `sk-or-`, `sk-`, `AQ.`, `AIza`, `pplx-`, `gh[pousr]_`, `github_pat_`, `hf_`, `xox?-`, PEM private-key and NKEY-seed blocks, NATS nkey seeds (`SU…`, `SA…`, `SO…`), JWTs (NATS `.creds`, OAuth), Telegram bot tokens, and AWS `AKIA`/`ASIA` ids;
- the value of any `api_key = …`, `"token": "…"` or `password: …` style assignment (qBraid keys included);
- the literal value of every environment variable whose name contains KEY, TOKEN, SECRET, PASSW, CREDENTIAL or SEED (for example `BUZZ_RELAY_PRIVATE_KEY`, `QBRAID_API_KEY`).

**Third-party text and OpenRouter.** Vigil runs on OpenRouter, so whatever Vigil reads goes to a non-Anthropic provider (with data collection denied, see above). `ferryman draft --input` passes its inputs to Vigil as sources. Do not pass sweep material (mail, DMs, inbox exports) to `draft --input` unless Nick accepts that route. Once Vigil is on the local LoRA, this no longer applies.

URL inputs (`--source URL`, `--fetch-links`, `--markets URL`) are fetched only from public hosts. The host is resolved first, and loopback, private (the 10.x lab range), link-local, CGNAT and reserved addresses are refused, also after a redirect, so a link in a document cannot pull Gatus on 127.0.0.1:8090 or a lab service into a prompt. `--fetch-links` skips such links; an explicit `--source` exits 2 with a ledger row.

## The ledger

Each row has the full rogue-agent `answers.jsonl` key set (`answer_id, identity, t_sent, t_done, model, model_digest, gateway_model, response_id, temperature, max_tokens, system, user, recall, collective, graph, content, content_sha256, usage, error`). `user` is the exact text sent, inputs included, and `recall` lists each input's name, sha256 and size. Extra keys the grader ignores: `arm, task, backend, prompt_version, model_sha256, upstream_provider, system_sha256, inputs_sha256, audited_input, verdict, verdict_json, json_valid, schema_errors, quote_check, cost_usd, cost_estimated, cost_over_estimate, budget, kannaktopus_rev`. `upstream_provider` is the provider OpenRouter routed to.

**File permissions.** On Linux and macOS the ledger, the reservations and Ferryman's files are created 0600 in 0700 directories. Windows ignores those modes, so when the runner creates one of its directories there it cuts the ACL to the current user with `icacls <dir> /inheritance:r /grant:r %USERNAME%:(OI)(CI)F`, and files created inside inherit it. Directories made before this change keep their old ACL: run that command on `~/.kannaktopus` once.

The layout matches rogue-agent's, so its grader reads the arms' rows unchanged:

```bash
python tools/fab_grader.py nightly --root ~/.kannaktopus/ledger
```

To grade Vigil's own error rate, put its verdicts on the blind regrade.

## Moving Vigil to the GLM LoRA

Vigil moves to `kannaka-brain-glm-v1` (a LoRA on `zai-org/GLM-4-9B-0414`) only after the LoRA passes its preregistered gate. Then the switch is `OCTOPUS_VIGIL_BACKEND=ollama`, or `"backend": "ollama"` in the config, pointed at the host that serves it. From then on rows carry `cost_usd: 0`, and `model_digest` is filled in when the server is ollama. llama-server has no `/api/tags`, so set `"model_sha256"` in `vigil.json` (or `OCTOPUS_VIGIL_MODEL_SHA256`) to the served GGUF's sha256; every row records it. On the local backend the request timeout is `timeout_s_local` (default 900 s), because a whole-document audit on CPU takes minutes. One way to check the LoRA before switching is to replay the OpenRouter-period rows from Vigil's ledger against it and compare the verdicts.

### Vigil LoRA preregistration (2026-11-08, before launch)

Recorded here, in git history, so the gate cannot move after the results are in. The gate is §3 of the plan whose sha256 is listed below: G1 voice ppl, G2 per-claim auditor (48 frozen items, reported per class), G4 sanity, G5 the production path through this runner on 12 whole documents, and G6 no worse than the GLM-5.3 stopgap. Vigil switches only if all of them pass. Nothing is launched by this PR.

| File | sha256 |
|---|---|
| PLAN.md (plan v2) | `f242f565508035e06ef27753b7bd54966abcb95f1027d9705f004be6c08af21a` |
| auditor_eval.jsonl (G2, 48 items, unchanged since v1) | `2333e4d993a80f3038aca501826bf6ace913003d4ea1052c7fb420dfb2d0c289` |
| g5/gold.json (G5, 12 documents) | `5d66adaeb062e5138c5a3173bca1b55e6e8e5c2d230b003e6bd0e52b9a223b7c` |
| train.jsonl (725 rows) | `b6a2ebb880e2d1e91970a4d947c3a55c6bdefd04f51662c9a312ef320bd9053b` |
| holdout.jsonl (G1 ruler, P1 2026-09-05) | `2775c8a10d293938b109a8ad49234e951ace1b2d86fa1e300bb48d53fdf7b83c` |
| build_dataset.py | `6c75901fc176008cd5e23da59c87cfed930002da3029c19ac3a9a792183a3ab9` |
| vigil_job.sh (pod job) | `6567849c3659445480eb54d259e8ce897eb7c505e6160de85082c0f2439ef32f` |
| eos_check.py | `ee0299f14829e7dfbbb9fe3aa03101e62033026b1793ef5039699f00e69ed826` |
| g2_eval.py (G2/G4 + scoring) | `6d7369f131e7983025f21f274ab31269d119743c6771d1c4e9432b2a346113bf` |
| g2_comparator.py (G6 on G2) | `e5448e7011653504cc1ad4882821d9427a40f71632b5db285745314b09da94b0` |
| g5_run.py (G5 + G6 on G5) | `0a96b38e0b2abdaac00a45b99048c0f166bcc1e125ea88735da462346d41831a` |
| agents/arms/vigil.md used for the whole-document rows (vigil-v2) | `f67811ff04e184454b461aed89456e395e5925c71ed9e001dab62206b4388994` |
