# Upstream lineage

WakeLease began as a derivative of [Adrafinil](https://github.com/kageroumado/adrafinil), created by **kageroumado** and its contributors. Its macOS power-management engineering, privileged helper, user daemon, IPC, process monitoring, safety policies, integration installers, and regression tests are the starting point of this project, not original WakeLease inventions.

## Baseline

- Stable release: **v1.7.0**, published August 24, 2026.
- Commit: `d21e8abd20bb777a3b8efff712a881e836a90598`.
- Reviewed and imported September 12, 2026.
- Full upstream Git history and release tags are retained.
- `upstream` points to `https://github.com/kageroumado/adrafinil.git`.
- No WakeLease public repository has been designated yet. `origin` is intentionally unset. No release is published by this checkout.

The original MIT license and copyright notice remain in `LICENSE`. Distribution must include that notice. Retained source paths and the internal `AdrafinilShared` module make upstream fixes easier to compare and port; they are not user-facing branding.

WakeLease is an independent project. Adrafinil's author and contributors do not endorse it. Upstream branding and artwork must not be included in WakeLease release artifacts. Historical assets remain in the imported history and are not permission to present the products as affiliated.

## Engineering to retain

- Ordinary IOPM idle assertions plus the experimentally verified `pmset -a disablesleep` clamshell mechanism. A successful private API return is not evidence of closed-lid behavior.
- One process-wide helper blocker; reconnects must not orphan assertions.
- Startup/shutdown cleanup, dead-man recovery, bounded subprocess calls, wake reconciliation, connection identity checks, and explicit `@Sendable` XPC error callbacks.
- Turn-scoped agent hooks, distinct subagent keys, process-tree sampling, versioned status snapshots, and configuration merges preserving foreign handlers.
- Regression coverage for upstream issues #2, #7, #12, #15, #17–#26.

## Intentional divergence

WakeLease generalizes work into leases, adds explicit waiting/lifetime/ownership semantics, and separates the stable local integration contract from agent-specific adapters. Critical changes must have regression tests, particularly final-release races and failures clearing persistent power state. Upstream implementation details are preserved unless there is a documented correctness or product reason to change them.

The [valentine/adrafinil Sequoia backport](https://github.com/valentine/adrafinil) was reviewed for deployment-target lessons: ServiceManagement is available before Tahoe, while upstream isolated deinits impose a macOS 15.4 Swift-runtime floor. This is build evidence, not WakeLease hardware certification.

[Decaf](https://github.com/grishahq/decaf) was examined for completion-triggered sleep and failsafe ideas. No Decaf code is incorporated. Its sudoers installation and shared `/tmp` state are not adopted.

## Maintaining lineage

Fetch `upstream` and review releases before porting changes. Preserve upstream authorship when cherry-picking. For a new bug, first write a reproducer and regression test; isolate an upstreamable fix when practical. Do not automatically open an upstream issue or pull request, or publish a derivative, without the maintainer's authorization.
