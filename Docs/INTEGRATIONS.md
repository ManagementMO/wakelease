# Integrations

WakeLease's daemon accepts generic leases. Agent knowledge belongs in adapters and generated hooks, never in the lease registry. An unknown tool can use `acquire`/`renew`/`wait`/`release`, `run`, or `watch` without a daemon change.

## Verification levels

**Contract/fixture verified** means current primary documentation or source was checked and our generated configuration/payload handling was tested. Execution fixtures additionally run the actual installed JSON hook commands for Claude Code/Codex/Cursor/Gemini, the executable Cline hooks, Hermes argument-vector recipes, and OpenCode's generated TypeScript event handler against a simulation broker. It does **not** mean an actual paid agent turn or physically closed MacBook was tested. **Host-SDK verified** additionally means the real pinned host SDK loaded and executed our generated extension, with a deterministic offline model instead of a paid provider. Pi has this additional coverage. No paid-provider, full interactive-host, or closed-lid certification is claimed.

| Tool | Current adapter | Evidence and limits |
| --- | --- | --- |
| Claude Code | Turn start/stop; independent subagents; session retirement; best-effort waiting/resume | `UserPromptSubmit`, `Stop`, `SessionEnd`, `SessionStart[clear]`, `SubagentStart/Stop`, `Notification`, `PostToolUse/Failure`. Contract/fixtures checked. Waiting notifications are not comprehensive. |
| Codex | Per-turn and independent subagent leases | Current source has `turn_id`, `Interrupt`, `SessionEnd`, permission and tool hooks. Approve every added handler using `/hooks`. Execution outside the interactive TUI is not certified; use `run -- codex exec ...` where needed. |
| Cursor | `beforeSubmitPrompt` / `stop` | Keyed on **conversation_id + generation_id**, not application lifetime. One-hour TTL backstop. Contract/fixtures checked. |
| Gemini CLI | `BeforeAgent` / `AfterAgent`, session cleanup | Replaces upstream session-lifetime holding. Automatic retry/approval behavior still requires live testing. |
| OpenCode | Generated TS plugin; busy/retry/idle status and permission/question events | No hold for an empty newly created session. Plugin is experimental until exercised against a live host. |
| Pi | Generated TS extension; `agent_start` / `agent_settled`, shutdown safety net | Uses `getSessionId()` rather than storing a session file path, and sends its own PID. Requires `agent_settled`. Host-SDK fixture verified on pinned Pi 0.83.0: real extension loading, overlapping independent sessions, PID ownership, final release and a subsequent turn, with all network attempts blocked and a mocked model. The user's older 0.79.4 installation is not certified. |
| Cline | Experimental VS Code task hooks | Current Unix discovery uses **extensionless executable names** in `~/Documents/Cline/Hooks`, not `.sh` files in `Rules/Hooks`. Existing user scripts cause a conflict rather than being replaced. The newer SDK/CLI plugin mechanism is separate and is not claimed supported by this installer. |
| Aider | Explicit command wrapper | `wakelease run -- aider ...`. Protects the process lifetime, including idle prompts; no claim of semantic turn/wait detection. No shell rc aliases are installed. |
| Hermes | Manual shell-hook recipe | `pre_llm_call` acquires per conversation run; `on_session_end` releases. Session IDs remain independent—never one shared `hermes:gateway` key. YAML merging and consent are left to the user rather than edited blindly or auto-approved. |

Installed versions observed with version-only commands: Claude Code 2.1.258, Codex 0.154.0, OpenCode 1.18.19, Pi 0.79.4, Hermes 0.20.5. Version presence is not integration execution evidence.

## Safe installation

```sh
wakelease integrations
wakelease integrations preview claude-code
wakelease integrations install claude-code --dry-run
wakelease integrations install claude-code --yes
wakelease integrations uninstall claude-code --dry-run
wakelease integrations uninstall claude-code --yes
```

Without `--yes`, applying changes requires interactive confirmation. Noninteractive calls must explicitly pass `--yes`. `--home <directory>` selects a different configuration home, useful for an isolated profile or testing. The default is the user's actual home. Custom agent-specific configuration-home environment variables are not automatically inferred by this initial installer.

The installer:

- Parses supported JSON shapes and refuses malformed containers or JSON-with-comments rather than replacing them with an empty object.
- Adds only its own handlers and keeps correct existing handler positions unchanged, important for Codex trust.
- Records an ownership receipt and a restrictive, byte-for-byte backup **before** modifying configurations.
- Uses atomic descriptor-relative writes, rejects symlinks/hard-link surprises, preserves existing file permissions, and compares the input again before writing.
- Restores original bytes on uninstall if the installed configuration was unchanged. If unrelated content changed, removes only the exact recorded handlers while retaining foreign content.
- Refuses to overwrite a plugin merely because its filename is `wakelease.ts`; without a receipt it is not ours.
- Refuses to silently delete an externally modified owned plugin or hook.
- Shows only intended integration changes in previews, never an entire third-party configuration that may contain credentials.

An unrelated program does not participate in WakeLease's installer lock. The read-before-write conflict check is therefore best-effort against simultaneous external writers; avoid editing the same configuration while applying changes. Ownership receipts also make partial writes diagnosable. Backups are retained under WakeLease's private `integrations` state directory after disconnecting; they are not uploaded.

Codex trust is intentionally not granted automatically. `needsApproval` is a reminder to check `/hooks`, not a claim that WakeLease can authoritatively inspect Codex's internal trust hash. Removing or moving groups can require re-approval of later indexed hooks, depending on the host's trust implementation.

Disconnecting an integration does not kill running jobs. Existing leases retain their normal lifetime; release them explicitly or pause WakeLease if you intend to allow sleep immediately.

## Custom producers

For shell lifecycle hooks with a unique work ID:

```sh
wakelease hooks generate --source my-tool --session-variable JOB_ID
```

The generated commands namespace keys as `<source>:<work-id>`, quote values, skip missing IDs, suppress hook output, and fail soft. Supply a nonempty ID unique to that concurrent job or turn, not merely to a long-lived application. Map the host's event payload to the chosen environment variable; it is not assumed to exist automatically. If your tool requires a JSON hook response, follow its output contract as well. Our first-class `wakelease hook <adapter> <action>` entry point returns `{}` and exit zero even if the broker is absent or the payload is malformed; a wake utility must not erase an agent's prompt or prevent a tool operation.

The native flow is **Settings → Integrations → Custom Integration…**. Choose a stable source ID, the work-ID variable, a finite lifetime and system/display class. Optional event labels help map the recipe to the host, but are never executed. Copy individual start/resume, wait, heartbeat and finish commands, or export the versioned recipe as JSON. Nothing is installed automatically.

Equivalent terminal flows:

```sh
wakelease hooks generate --interactive
wakelease hooks generate --source my-tool --session-variable JOB_ID --for 1h --json
wakelease hooks generate --source gui-tool --for 30m --display \
  --start-event BeforeWork --stop-event AfterWork --executable /path/to/tool
```

`--interactive` requires a terminal. `--json` is noninteractive and emits recipe schema version 1, not a universal host configuration file. Event labels are descriptive; install only hooks the actual tool supports. `--for` accepts a duration, or use `--ttl` for seconds. The recipe lifetime is limited to 24 hours. Start also resumes work; waiting follows the user's configured waiting policy. Send heartbeats before expiry if work lasts longer than its lease. System-only is the default.

For processes without semantic hooks:

```sh
wakelease run -- npm run build
wakelease watch --pid 12345
wakelease hold --for 2h --source download --reason "large download"
```

A wrapper is explicit process-lifetime protection. An interactive shell still alive at a prompt is not known to be doing useful work. Prefer hooks where possible; otherwise use a finite hold or stop the wrapper when appropriate.

For background work outliving a parent turn, acquire an independent timed/process-bound lease **before** releasing the parent's lease. `--parent <lease-uuid>` records the relationship, but parent release never removes children.

## Hermes manual recipe

```sh
wakelease hooks generate --source hermes
```

Merge the printed `pre_llm_call` and `on_session_end` commands into the existing `hooks` map, preserving other entries. Hermes runs these through an argument-vector subprocess rather than an elevated shell; approve them through Hermes's own consent flow. Do not substitute `pre_gateway_dispatch` as proof of an active run: it occurs before authorization/dispatch and may not be paired with a run completion.

## Optional local MCP

Run `wakelease mcp --source <tool>` as a stdio MCP server. Add it manually to the host's MCP configuration using the installed executable path. It exposes:

- `keep_system_awake`
- `keep_display_awake`
- `release_wake_lease`
- `get_wake_status`

Supply a background `pid` when possible; the server verifies process identity through the same broker API. Otherwise choose a finite `minutes` duration and release the returned `lease.key` promptly. `parentLeaseID` is optional. Tool results include the broker's status and power report; simulation must not be mistaken for applied power protection.

This implementation negotiates **MCP 2025-03-26 / 2024-11-05**, with the initialize/initialized stdio lifecycle. The newer **2026-07-28 per-request metadata protocol is not implemented**. Clients requiring that revision should use the CLI/local lease API or a compatible MCP mode. There is no HTTP transport, account, cloud service, or exposed network port.

## Primary references

- Claude Code: https://code.claude.com/docs/en/hooks
- Codex schema/config: https://github.com/openai/codex/blob/main/codex-rs/hooks/src/schema.rs and https://github.com/openai/codex/blob/main/codex-rs/config/src/hook_config.rs
- Cursor: https://cursor.com/docs/hooks
- Gemini CLI: https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md
- Pi: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md and its `session-manager.ts` implementation
- OpenCode: https://github.com/anomalyco/opencode/blob/dev/packages/schema/src/session-status-event.ts
- Cline: https://github.com/cline/cline/blob/main/apps/vscode/src/core/hooks/hook-factory.ts and https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts
- Hermes: https://github.com/nousresearch/hermes-agent/blob/main/agent/shell_hooks.py and https://github.com/nousresearch/hermes-agent/blob/main/agent/turn_context.py
- MCP compatibility schema: https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-03-26/schema.ts
