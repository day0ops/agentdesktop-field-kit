# Update to latest agentdesktop, with Claude Code/Codex as managed programs

## Intent and why

The field kit is pinned to agentdesktop `v0.1.1` (Sept 2026). Five releases
have shipped since (`v0.2.0`-`v0.6.0`, through Nov 6 2026), and the demo it
drives has not kept pace with what the product actually does. Today the
wizard only gets a device enrolled with the controller - the rendered
`config.yaml` sets `controller.*` and nothing else, so the pilot never sees
agentdesktop's actual value: managing AI coding tool configuration and
credentials on a device, with visibility and policy per user.

Upstream now has everything needed to demonstrate that properly:
notarized macOS PKG installers (removing the reason this kit's Intune step
was a documented workaround), a daemon config schema with `programs.*` and
`llmGateway` blocks for Claude Code and Codex, a tested subscription-auth
path for both tools (Claude Team/Enterprise, ChatGPT), and - confirmed
against Solo's own agentgateway docs/knowledgebase - real, shipped
per-identity policy enforcement (rate limits and token budgets keyed on a
JWT claim, not just logging).

This project updates the kit to the current agentdesktop release and uses
that update to make the demo show individually-tracked users and policy
enforcement across both Claude Code and Codex, under either a real
subscription or a pooled API key.

JumpCloud/MDM-alternatives support is a separate, later project and is not
part of this one.

## Goals

- Track the current agentdesktop release (`v0.6.0` as of this writing),
  not a five-release-stale pin.
- Claude Code and Codex are both configured as agentdesktop-managed
  programs, kept as separate, independently selectable units - not an
  all-or-nothing pair. A pilot can run either one alone or both together.
  Each is independently selectable between two auth modes:
  - **Subscription** (default): Claude Code via a real Claude
    Team/Enterprise seat, Codex via a real ChatGPT account - both using
    agentdesktop's OAuth credential-helper flow, matching upstream's
    `examples/claude-subscription` / `examples/codex-subscription`.
  - **API key** (opt-in): Claude Code via `ANTHROPIC_API_KEY` against
    Anthropic directly (today's pattern, matching
    `examples/claude`); Codex via its own `OPENAI_API_KEY` against
    OpenAI directly (native dialect, no protocol translation). Selected
    automatically per program when the corresponding env var is present
    at run time - no new interactive prompt.
- Per-user policy enforcement is visibly demonstrated: a request-rate
  limit and a token budget, each keyed on the pilot user's identity from
  the controller-issued JWT, applied at the agentgateway layer
  regardless of which auth mode is active.
- Intune deployment moves from the raw-binary/shell-script workaround to
  native macOS PKG app deployment of the real notarized package, and the
  daemon runs in user mode (required for subscription auth on both
  tools) instead of system mode.
- README and preflight reflect the new prerequisites and drop the
  "not a real production path" caveat around the Intune step.

## Non-goals / anti-goals

- JumpCloud or any other MDM - separate project, brainstormed next.
- Rate limiting/budgets shared across multiple agentgateway replicas
  (would need a global rate-limit service). A single local instance's
  in-memory buckets are sufficient for a pilot.
- Changes to the Entra ID device-enrollment flow itself (mTLS issuance,
  OIDC consent, pilot group creation) - unaffected by this work.
- Windows/Linux daemon support - this kit targets macOS only, as today.
- Settling whether routing a real ChatGPT subscription through
  agentdesktop/agentgateway this way is compliant with OpenAI's terms for
  production use - upstream's own docs flag this as unvalidated against a
  real paid account for anything beyond their test fixtures. This kit
  will carry that same caution into its README rather than resolve it.
- It would be a failure to end up with a kit that *looks* updated (new
  version pin) but still only demonstrates bare enrollment - the
  managed-programs and per-user-policy pieces are the point, not a
  stretch goal.

## Constraints

- Same-day pilot kit. No code-signing/notarization identity of our own
  is needed any more - we consume upstream's own notarized PKG.
- Every modified or new script keeps the existing `--dry-run`/`--help`/
  resumable-step conventions (`state/wizard-progress`).
- `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are only ever read from the
  environment, never hardcoded, never written to disk - same rule the
  kit already follows for `ANTHROPIC_API_KEY` today.
- The two-machine topology (controller on one machine, agentgateway +
  daemon on another) must keep working.

## Decided design

**Version pins.** `20-controller-up.sh`'s default `image_tag` moves from
`v0.1.1` to the current latest (`v0.6.0` at design time); `--image-tag`
override stays. The daemon/CLI binary resolution in `30-daemon-enroll.sh`
and `41-intune-push.sh` is already dynamic (defaults to GitHub "latest",
accepts `--version`) and needs no change in that regard - only in what it
installs and how (see below). `21-agentgateway-up.sh`'s pinned agentgateway
image also moves, from `v1.4.1` to `v1.6.0` - the version upstream's own
`claude-subscription`/`codex-subscription` examples are built and tested
against (`jwtAuth.location.expression`, `transformations`, and the
composite-bearer pattern are not confirmed to exist in `v1.4.1`). `v1.7.0`
exists upstream but isn't what the reference examples target, so stay on
`v1.6.0` unless a later pass finds a specific reason to move.

**Local (non-Intune) daemon path.** `30-daemon-enroll.sh` installs the
binary and prints a command for the operator to run by hand; today that's
`sudo "${install_path}" daemon --config ...`, i.e. a foreground system-mode
process. That changes to `"${install_path}" daemon --user --config ...`
(no `sudo` on the run step - only the binary install itself still needs
it to write to `/usr/local/bin`), so this path demonstrates the same
user-mode/subscription behavior as the Intune path instead of diverging
from it.

**Persisting the chosen auth mode.** Each program's mode (subscription vs.
API-key) is resolved once, the first time it matters, and written to
`state/demo.env` as `CLAUDE_AUTH_MODE` / `CODEX_AUTH_MODE` (same
`env_file_set`/`load_env_file` mechanism already used for
`CONTROLLER_PUBLIC_ADDRESS` etc.) rather than re-read from the environment
independently by every script. That keeps `21-agentgateway-up.sh`'s
rendered `agentgateway.yaml` and `41-intune-push.sh`'s/`30-daemon-enroll.sh`'s
rendered `config.yaml` from silently disagreeing about which mode a
program is in, including across the two-machine topology and across
resumed wizard runs.

**Auth-mode selection.** For each of Claude Code and Codex independently:
if the program's API-key env var is set when the relevant script runs,
configure that program in API-key mode; otherwise configure it in
subscription mode. This mirrors `21-agentgateway-up.sh`'s existing
`ANTHROPIC_API_KEY`-presence gate - no new prompt, no new flag required
to get the default behavior.

**agentgateway.yaml**, per program and mode:
- API-key mode: a `models` entry with a static `params.apiKey`
  (`provider: anthropic` for Claude Code, `provider: openai` for Codex) -
  today's proven pattern, matching upstream's `examples/claude`.
- Subscription mode: a dedicated `llm` listener with the composite-bearer
  `jwtAuth.location.expression` (extracting the inner identity token) and
  a `transformations` rule restoring the real subscription credential
  upstream, copied from upstream's `examples/claude-subscription` /
  `examples/codex-subscription`.
- Either way, two `llm.policies.localRateLimit` rules are added: one
  `type: requests` (requests-per-minute) and one `type: tokens` (the token
  budget - confirmed to be the same policy primitive, not a separate or
  enterprise-only feature), each with `key: jwt.email` (or `jwt.sub` if
  the controller's JWT turns out not to carry an email claim - confirm
  during implementation), so usage is individually tracked and throttled
  per pilot user rather than pooled.

**Daemon config** gains `programs.claudeCode` / `programs.codex` blocks
matching each program's selected mode, and `llmGateway.authentication.
allowedClientIds` listing whichever client IDs are active.

**Intune deployment** (`41-intune-push.sh` rewrite): push the notarized
`.pkg` as a native Intune macOS line-of-business app (instead of a
deviceShellScript running a raw binary), assigned to the pilot group.
`lib/upsert-intune-script.sh` is kept, not deleted, but shrinks: it's no
longer responsible for downloading/installing the binary, only for a
companion deviceShellScript that writes the rendered `config.yaml`/device
CA to disk and bootstraps the daemon as a **user-mode LaunchAgent**
(instead of today's system LaunchDaemon) for whichever user is on the
console - matching the existing console-user-detection logic already in
this script, just retargeted at `launchctl bootstrap gui/<uid>` instead
of `system`. The PKG app and the companion script are assigned to the
same pilot group so both land together.

**Pick-and-choose programs.** Claude's and Codex's agentgateway-config and
daemon-config fragments are written and templated as separate, independently
valid units (mirroring upstream's separate `examples/claude*` /
`examples/codex*` directories), not one hardcoded combined block. A new
`--programs claude,codex` flag (default: both) on the relevant scripts
selects which fragments get rendered and composed into
`agentgateway.yaml`/`config.yaml`; the persisted selection lives in
`state/demo.env` alongside the per-program auth mode, so a pilot that only
wants to demo one tool - or hits the simultaneous-subscription risk above -
can rerun with `--programs claude` (or `--programs codex`) and get a fully
working single-program setup.

**Preflight and partial demos.** `00-preflight.sh` checks for Claude Code
and Codex (>= 0.153.4) on the pilot Mac and warns, rather than hard-fails,
per tool that's missing or out of date - a program is only added to the
rendered daemon config if it's both selected (`--programs`) and its
preflight check passed, so the wizard still works end-to-end for a pilot
that only wants to demo one of the two tools.

**Validation scope.** `50-validate.sh` automates what it can - daemon
enrolled and connected, each configured program's managed settings
reported present by `agentdesktop status`, and firing enough rapid
requests through agentgateway to confirm the per-user rate limit actually
returns a 429. The interactive pieces (browser sign-in succeeding, a real
Claude Code/Codex session working end to end) stay manual, called out in
the script's output rather than automated.

**New manual demo step.** In subscription mode, after the daemon applies
configuration, the pilot operator signs into Claude.ai and/or ChatGPT in
a browser - documented in the README/console output the same way today's
Entra ID consent step is.

## Known risk: one shared `llmGateway` block for two programs

The daemon config schema has exactly one top-level `llmGateway` block
(`llmGateway.url`, `llmGateway.authentication`) - it is not per-program.
Upstream's two subscription examples each set it to a different address
(`examples/claude-subscription`: `http://127.0.0.1:4000`;
`examples/codex-subscription`: `http://127.0.0.1:4002/v1`) and each example
configures exactly one program; neither shows both `programs.claudeCode`
and `programs.codex` in subscription mode on the same daemon at once, and
Claude's Anthropic-composite-bearer listener and Codex's OpenAI/ChatGPT-
composite-bearer listener need different ports, different
`jwtAuth.location.expression` parsing, and different upstream targets.

Decision: proceed straight to implementation without a dedicated spike.
The mitigation is the "pick and choose" structure above - Claude's and
Codex's agentgateway/daemon-config fragments are built and kept as
separate, independently valid units (see below), so if running both
simultaneously in subscription mode turns out not to compose cleanly
behind one `llmGateway.url`, the kit still works cleanly with either one
selected alone, and that fallback costs nothing extra to fall back to.

## What's left to the builder

- The exact Microsoft Graph payload for a macOS PKG line-of-business app
  (`deviceAppManagement/mobileApps`, `macOSPkgApp` type) versus today's
  `deviceShellScripts` call in `lib/upsert-intune-script.sh` - needs its
  own short research pass against the Graph API during implementation.
- Confirming whether the controller's `gatewayJwt` includes an `email`
  claim (fall back to `jwt.sub` for the rate-limit/budget key if not).
- Picking rate-limit/budget numbers that are easy to visibly trip live
  during a demo (e.g. a low requests-per-minute cap) - exact values are
  not load-bearing to the design.
- Whether the LaunchAgent plist goes in `/Library/LaunchAgents` (loads
  for whichever user is on console, matching today's group-membership
  check) versus a specific user's `~/Library/LaunchAgents` - recommend
  the former for parity with the existing pattern, but this is a minor
  call either way.
