---
name: Bug report
about: Report a problem with WakeLease (Mac won't sleep, sleeps mid-work, a hook not firing, etc.)
title: ""
labels: ""
assignees: ""
---

## Summary

<!-- One or two sentences: what happens, and when. e.g. "Mac sleeps while a background sub-agent is still running" or "Mac stays awake after the agent finished". -->

## Environment

- **WakeLease**: <!-- e.g. 1.4.0 (menu bar → About, or the GitHub Release) -->
- **macOS**: <!-- e.g. 26.1 (Build 25B?) -->
- **Hardware**: <!-- e.g. M4 MacBook Air; on battery / on AC; lid open / clamshell -->
- **Agent(s)**: <!-- which agent hooks are connected — Claude Code / Codex / Cursor / Gemini / Aider / a custom "Add your own agent" — and its version -->

## Steps to reproduce

1.
2.
3.

## Expected behavior

<!-- What you expected — e.g. "stays awake until the background task finishes" or "lets the Mac sleep once the agent is idle". -->

## Actual behavior

<!-- What actually happened. -->

## State (optional but helpful)

After reproducing, capture:

- **`wakelease status`** — shows the active holds/assertions and whether the daemon helper is connected:

  ```sh
  wakelease status
  ```

- **Which hooks are installed** — Settings → Agents in the app, or the agent's own config:
  - Claude Code: `~/.claude/settings.json`
  - Codex: `~/.codex/hooks.json` (must be trusted via `/hooks`)

## Log excerpt

WakeLease logs to the unified log. Capture the window around the problem:

```sh
log show --last 15m --predicate 'subsystem BEGINSWITH "org.wakelease"' --style compact
```

Include only a sanitized excerpt. Lease events are local under the private state directory; do not attach whole hook configurations, prompts, transcripts, keys, or lease reasons. There is no enabled CPU-idle sniffer in the new runtime.

## Recovery note

Use **Allow Sleep Now** or `wakelease pause` to deliberately release work and block new leases. Quitting only the menu bar does not stop the daemon. Run `wakelease doctor` and consult `Docs/RECOVERY.md` if cleanup is unconfirmed. Do not delete recovery services or publish raw configuration. Label evidence as simulation, signed-peer testing, or actual physical behavior.
