# Architecture notes

## Data sources and gotchas

- Daily usage comes from the bundled `tokscale` (npm-published binary in `Resources/tokscale/`). Its three period scans must stay serial (concurrent scans triple CPU/IO).
- On launch `HistoryStore` absorbs the old Token Monitor archive (`~/Library/Application Support/Token Monitor/daily-history-archive.json`, read-only, larger-observation-wins, idempotent).
- tokscale has no intraday resolution. `IntradayScanner` reads `~/.claude/projects/**/*.jsonl` directly: chunked reads, `memchr`/`memmem` byte search, dedup by `message.id` + `requestId`. It only reads timestamps, the model id and token counts, keeping 90 days of per-model half-hour buckets. Re-check totals against a full-JSON reference if the parser changes. Claude Code only — Codex has no intraday source yet.
- Claude limits: Claude Web `sessionKey` probe (new Claude Code builds keep no OAuth token on disk); a rotated cookie must be written back or it dies.
- Codex limits: `codex app-server` JSON-RPC with `-s read-only -a never` (`untrusted` was removed from the CLI). The codex binary may live inside `ChatGPT.app` rather than on `PATH`.
- Spawned CLIs must get `ProcessRunner.cleanEnvironment()` — inheriting `CLAUDE_CODE_*` from a Claude Code session turns a child `claude` into an API-billed sub-session. macOS has no `timeout` command.
- Cursor and Grok Bot (a Cursor app) keep no usage logs on the Mac. `CursorSync` runs `tokscale cursor login` once (from the Cursor desktop app's sign-in) and `tokscale cursor sync` before a full scan, at most hourly: the sync pulls the account's whole usage history (tens of seconds, a few MB). tokscale reports both as client `cursor`; `TokscaleReport.normalizeClient` turns `grok-bot-*` models into the `grokbot` tool.
- `CursorProbe` reads the Cursor access token from Cursor's `state.vscdb` (or tokscale's copy) and calls Cursor's dashboard RPC `GetSandUsageStatus` for the weekly window, `GetCurrentPeriodUsage` for on-demand spend, and `get-plan-info` for the plan name (merged plans are shown as "X Pass"). SimpleToken stores none of it.
