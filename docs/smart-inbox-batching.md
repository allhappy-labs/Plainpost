# Smart Inbox batch profiles

Plainpost defaults to one message per Smart Inbox provider request. A larger batch is used only when the database contains an approved profile whose provider ID, model ID, schema version, and prompt version exactly match the active classifier. Missing or stale profiles therefore remain at size one.

## Safe benchmark inputs and outputs

`PlainpostSmartInboxBenchmark` uses a fixed corpus of 80 synthetic compact-message records. It does not open the application database, enumerate accounts, or read mailbox content. The corpus covers every Smart Inbox category, all three priorities, both action states, long previews, Unicode, empty display names, invitations and responses, receipts, password alerts, travel changes, and ambiguous low-confidence mail.

The JSON output contains aggregate counts, quality scores, coverage, diagnostics, prompt-size distributions, latency, memory, runtime-correctness results, and the selected aggregate profile. It contains no sender, subject, preview, prompt, or per-message prediction text. Provider-process RSS is `null` unless `--provider-pid` is explicitly supplied and the process can be sampled. Current-process RSS is also nullable; if any required worker RSS sample fails, memory evidence is unavailable and every size above one fails closed.

A normal run requires `--output` but never opens or changes a database. Profile persistence is opt-in through `--approve-database <sqlite-path>`. Approval transactionally creates only the Smart Inbox batch-profile table when needed and writes only the selected aggregate profile; it does not run full mail-store migrations or persist the corpus or predictions. If the provider is unavailable, the command records it as unbenchmarked, retains the size-one fallback, and does not approve a profile.

## Acceptance gates

Batch size one is the baseline. A candidate size above one passes only when every condition below is true:

- Category macro F1 is no more than `0.02` below baseline.
- Priority accuracy is no more than `0.02` below baseline.
- Action precision and action recall are each no more than `0.02` below baseline.
- Confidence calibration error is no more than `0.02` above baseline.
- Raw requested-ID coverage is at least `0.99`.
- Requested-ID coverage after the production halving recovery policy is exactly `1.0`.
- Warm median latency per message is at least 20% better than baseline: candidate latency is at most `0.80 * baseline`. Each outer representative request contributes exactly one end-to-end latency sample divided by its original message count, including all recursive recovery calls.
- Peak resident memory is at most `1.25 * baseline` and at most the configured absolute memory ceiling.
- Neither worker nor optional provider retained memory grows monotonically with a fitted slope greater than 1 MiB per batch. Either process independently triggers the unbounded-growth failure.
- Scripted cancellation, valid-sibling checkpoint persistence, and smaller-batch recovery checks all pass through `SmartInboxBatchRunner`.

The evaluator selects the largest passing size. If no size above one passes, it returns a size-one fallback profile. That fallback is not evidence that size one passed the latency-improvement gate.

## Running locally

Foundation Models:

```bash
swift run PlainpostSmartInboxBenchmark \
  --provider foundation \
  --model apple-foundation-system \
  --batch-sizes 1,4,8,12,16 \
  --quality-passes 3 \
  --repetitions 20 \
  --absolute-memory-mb 1024 \
  --output /private/tmp/plainpost-foundation-smart-inbox-benchmark.json
```

Ollama, using the concrete loopback endpoint and chat model configured in Plainpost:

```bash
swift run PlainpostSmartInboxBenchmark \
  --provider ollama \
  --model qwen3:8b \
  --ollama-url http://127.0.0.1:11434 \
  --batch-sizes 1,4,8,12,16 \
  --quality-passes 3 \
  --repetitions 20 \
  --absolute-memory-mb 2048 \
  --output /private/tmp/plainpost-ollama-smart-inbox-benchmark.json
```

`--repetitions` is the number of additional warm representative requests after warm-up, not additional full-corpus passes, and must be at least 20. Use `--provider-pid <pid>` when separate RSS sampling is needed for a local Ollama process. `--max-prompt-characters` can set an explicit prompt ceiling; otherwise the production provider capability budget is used.

To approve the selected profile, rerun the benchmark with an explicit database path:

```bash
swift run PlainpostSmartInboxBenchmark \
  --provider foundation \
  --model apple-foundation-system \
  --batch-sizes 1,4,8,12,16 \
  --quality-passes 3 \
  --repetitions 20 \
  --absolute-memory-mb 1024 \
  --output /private/tmp/plainpost-foundation-smart-inbox-benchmark.json \
  --approve-database /absolute/path/to/Plainpost.sqlite
```

Review the aggregate JSON before approval. Never approve a size above one from deterministic test providers, unavailable providers, incomplete runs, or manually edited results.

Rerun and explicitly reapprove after changing the provider, model, classifier prompt, response schema, or after a material OS, Foundation Models, Ollama, or runtime change.
