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
- Ferryman's collectors are read-only commands you configure. Each runs without a shell and under a timeout, and its stdout becomes one input. Collectors must never mark mail as read, reply or post.

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
```

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

It flags invented first-person memories (rules-v2 rule MR) and gives an overall PUBLISH, FIX or DROP. The runner checks the reply against the schema: a SUPPORTED or REFUTED claim that cites no provided input, or a PUBLISH that carries a REFUTED claim, fails with exit 4. The reply is kept in the ledger either way.

`ferryman settle` and `ferryman draft` run Vigil on their own output automatically. A draft counts as ready for Nick only after Vigil returns PUBLISH or FIX.

## Settlements

`ferryman settle` reads the public `markets.jsonl` from the Hugging Face dataset `Kannaka/calls-and-settlements`. It picks the rows with `outcome == null` and `settles_by` on or before today, or the one market named with `--market`. Without `--evidence` it lists what is due and what evidence each needs, and makes no model call. If the evidence does not state the deciding fact for the exact subject, date and threshold, the outcome is INCONCLUSIVE.

## Cost caps

Before every call the runner computes a worst case: input characters / 3 at the input price, plus `max_tokens` at the output price. It refuses the call (exit 3, no HTTP request) when:

- the worst case is over the per-run cap, or
- the spend over the last 7 days, summed from the arm's own ledger (`cost_usd`), plus the worst case is over the weekly cap, or
- the input is over `max_input_chars`.

A refusal still writes a ledger row with `error="budget: ..."`. After a call, the real cost is recorded: OpenRouter's `usage.cost`, or the Anthropic token counts times the price table in `named_arms.py`. Each call is also booked in the session usage log with role `actual`, so `orchestrate.sh cost` shows it.

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

Keys come only from the environment: `OPENROUTER_API_KEY` for Vigil, `ANTHROPIC_API_KEY` for Ferryman. The runner never reads a key file. It masks anything shaped like a key (`sk-ant-`, `sk-or-`, `sk-`, `AQ.`, `AIza`, `pplx-`, `ghp_`, `github_pat_`, `hf_`, plus the literal values of the key variables) in prompts, inputs, replies and errors, before sending and before logging.

## The ledger

Each row has the full rogue-agent `answers.jsonl` key set (`answer_id, identity, t_sent, t_done, model, model_digest, gateway_model, response_id, temperature, max_tokens, system, user, recall, collective, graph, content, content_sha256, usage, error`). `user` is the exact text sent, inputs included, and `recall` lists each input's name, sha256 and size. Extra keys the grader ignores: `arm, task, backend, prompt_version, system_sha256, inputs_sha256, verdict, verdict_json, json_valid, schema_errors, cost_usd, budget, kannaktopus_rev`.

The layout matches rogue-agent's, so its grader reads the arms' rows unchanged:

```bash
python tools/fab_grader.py nightly --root ~/.kannaktopus/ledger
```

To grade Vigil's own error rate, put its verdicts on the blind regrade.

## Moving Vigil to the GLM LoRA

Vigil moves to `kannaka-brain-glm-v1` (a LoRA on `zai-org/GLM-4-9B-0414`) only after the LoRA passes its preregistered gate. Then the switch is `OCTOPUS_VIGIL_BACKEND=ollama`, or `"backend": "ollama"` in the config, pointed at the host that serves it. From then on rows carry `cost_usd: 0`, and `model_digest` is filled in when the server is ollama (llama-server has no `/api/tags`, so the digest stays null). One way to check the LoRA before switching is to replay the OpenRouter-period rows from Vigil's ledger against it and compare the verdicts.
