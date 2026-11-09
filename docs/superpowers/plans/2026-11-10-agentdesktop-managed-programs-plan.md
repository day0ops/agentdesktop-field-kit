# Managed Programs (Claude Code & Codex) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the field kit to the current agentdesktop/agentgateway releases and make Claude Code and Codex real, independently-selectable, per-user-tracked managed programs instead of bare device enrollment.

**Architecture:** Two new pieces of state - which programs are selected (`claude`, `codex`, or both) and which auth mode each uses (`subscription` default, `api-key` opt-in) - are resolved once by a new non-interactive script and persisted to `state/demo.env`. `20-controller-up.sh` and `21-agentgateway-up.sh` read that state and render `programs.*`/`llmGateway`/`llm.policies` blocks accordingly, instead of today's static, program-less templates. Per-user rate limiting and token budgets are added at the agentgateway layer, keyed on the controller-issued JWT's identity claim.

**Tech Stack:** Bash (existing kit conventions: `set -euo pipefail`, `lib/common.sh` helpers, `--dry-run`/`--help`, `env_file_set`/`load_env_file`), agentdesktop daemon/controller config (YAML), agentgateway config (YAML + CEL), gum (wizard prompts in `run-demo.sh`).

**Spec:** `docs/superpowers/specs/2026-11-10-latest-agentdesktop-managed-programs-design.md`

This plan covers everything in that spec except the Intune/MDM delivery
mechanism, which is its own plan:
`docs/superpowers/plans/2026-11-10-agentdesktop-intune-pkg-plan.md` (depends
on this plan's `MANAGED_PROGRAMS`/`*_AUTH_MODE` state and user-mode daemon
convention, but is independently shippable as a separate delivery path).

## Global Constraints

- Controller image tag default moves `v0.1.1` → `v0.6.0`; agentgateway image
  tag default moves `v1.4.1` → `v1.6.0`. Both keep their existing
  `--image-tag` override flags.
- `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are only ever read from the
  process environment, never hardcoded, never written to `state/demo.env`
  or any rendered file.
- Every modified or new script keeps `--dry-run`, `--help`, and (where it
  already exists) idempotent re-run behavior.
- Claude Code and Codex are independently selectable - the kit must work
  with either one alone or both together.
- The two-machine topology (`--role controller` / `--role gateway`) keeps
  working: state persisted by scripts run on one machine must be readable
  by scripts run on the other via the existing `state/demo.env` mechanism.
- Token budgets use the same `localRateLimit` policy as request-rate
  limits (`type: tokens` vs `type: requests`), not a separate policy.

## Review Focus

- **Neither `ANTHROPIC_API_KEY` nor `OPENAI_API_KEY` set, subscription
  mode for both programs:** the kit must not silently fall back to
  API-key mode or crash - it should render both programs in subscription
  mode and tell the operator about the live sign-in step.
- **Only one of the two keys set (e.g. `ANTHROPIC_API_KEY` present,
  `OPENAI_API_KEY` absent):** Claude Code must land in API-key mode and
  Codex in subscription mode independently - a shared "if any key is set,
  use API-key mode for everything" bug would be wrong.
- **`--programs claude` (Codex not selected) re-run after a previous run
  had both selected:** the rendered `daemon.yaml`/`agentgateway.yaml` must
  drop Codex's blocks entirely, not leave stale `programs.codex`/model
  entries from the earlier run.
- **Resuming a two-machine wizard run where `15-managed-programs.sh` ran
  on the controller machine but `21-agentgateway-up.sh` runs on the
  gateway machine:** the gateway machine must read the same
  `MANAGED_PROGRAMS`/`*_AUTH_MODE` values via `state/demo.env`, not
  re-derive them independently from its own local environment variables.
- **Rate limit key claim missing from the JWT** (e.g. `jwt.email` absent
  because the controller's token doesn't carry it): the rendered
  `localRateLimit`/`authorization` config must not reference a claim that
  silently evaluates empty for every caller and collapses everyone into
  one shared bucket - confirm the claim exists before wiring the key, or
  fall back to `jwt.sub`.

---

## Task 1: Preflight checks for Claude Code and Codex

**Files:**
- Modify: `scripts/00-preflight.sh`
- Test: manual invocation (this repo has no test framework beyond
  `shellcheck`/`bash -n` in CI; verification steps below use those plus
  direct script runs, matching existing convention)

**Interfaces:**
- Produces: `state/demo.env` keys `CLAUDE_CODE_PRESENT` (`true`/`false`),
  `CODEX_PRESENT` (`true`/`false`), `CODEX_VERSION` (string, empty if not
  present) - written via the existing `env_file_set` helper from
  `lib/common.sh`. Consumed by Task 2.

- [ ] **Step 1: Add a `check_optional` helper and two checks**

  After the existing `check()` helper and its `docker`/`az`/`jq`/`curl`/
  `openssl`/`base64` calls (around line 28), add:
  - A check for `claude` on PATH (Claude Code's CLI binary name). On
    found: `env_file_set CLAUDE_CODE_PRESENT true` and
    `log_success "claude found ($(command -v claude))"`. On missing:
    `env_file_set CLAUDE_CODE_PRESENT false` and
    `log_warn "claude not found - Claude Code won't be configured as a managed program unless you pass --programs claude later"`.
    This check must **not** increment `failures` (`00-preflight.sh` hard-fails
    on missing required commands; Claude Code/Codex are optional per the
    design's pick-and-choose goal).
  - A check for `codex` on PATH, same pass/warn shape, writing
    `CODEX_PRESENT`. When found, also run `codex --version` and
    `env_file_set CODEX_VERSION "$(codex --version | ...)"` (strip to just
    the version string); if the parsed version is lower than `0.153.4`,
    additionally `log_warn "codex ... is older than 0.153.4, the version agentdesktop's subscription flow is validated against"` (still don't fail).

- [ ] **Step 2: Run shellcheck and bash -n**

  Run: `shellcheck -x -S warning scripts/00-preflight.sh && bash -n scripts/00-preflight.sh`
  Expected: no output, exit 0.

- [ ] **Step 3: Run the script directly and inspect state**

  Run: `scripts/00-preflight.sh` (on a machine with at least `docker`,
  `az`, `jq`, `curl`, `openssl` installed and Docker running - reuse
  whatever setup already satisfies today's preflight).
  Expected: script still exits 0 (assuming today's required-tool checks
  pass), and `state/demo.env` contains `CLAUDE_CODE_PRESENT=`/
  `CODEX_PRESENT=` lines reflecting whether `claude`/`codex` are on PATH.

- [ ] **Step 4: Commit**

  ```bash
  git add scripts/00-preflight.sh
  git commit -m "Warn (don't fail) preflight on missing Claude Code/Codex"
  ```

## Task 2: `15-managed-programs.sh` - resolve and persist program/mode selection

**Files:**
- Create: `scripts/15-managed-programs.sh`
- Test: manual invocation per the repo's existing convention (no unit
  test framework; see verification steps)

**Interfaces:**
- Consumes: `CLAUDE_CODE_PRESENT`, `CODEX_PRESENT` from `state/demo.env`
  (Task 1); `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` from the process
  environment.
- Produces: `state/demo.env` keys `MANAGED_PROGRAMS` (comma-separated
  subset of `claude,codex`, no spaces, e.g. `claude,codex` or `claude`),
  `CLAUDE_AUTH_MODE` (`subscription`|`api-key`, only set if `claude` is in
  `MANAGED_PROGRAMS`), `CODEX_AUTH_MODE` (`subscription`|`api-key`, only
  set if `codex` is in `MANAGED_PROGRAMS`). Consumed by Tasks 3, 4, 5, 6, 7.

- [ ] **Step 1: Write the script's argument parsing and usage**

  New file, following the existing script header convention
  (`set -euo pipefail`, source `lib/common.sh`, a `usage()` heredoc).
  Flags: `--programs LIST` (comma-separated subset of `claude,codex`;
  default: both, filtered to whichever of `CLAUDE_CODE_PRESENT`/
  `CODEX_PRESENT` from state is `true` - if *neither* preflight var is
  set at all, i.e. `00-preflight.sh` wasn't run or ran before this
  change, default to including both rather than silently excluding
  everything), `--claude-auth-mode MODE`, `--codex-auth-mode MODE`
  (each `subscription`|`api-key`; default per program: `api-key` if that
  program's env var - `ANTHROPIC_API_KEY` for claude,
  `OPENAI_API_KEY` for codex - is set in the environment, else
  `subscription`), `--dry-run`, `--help`.

- [ ] **Step 2: Validate and persist**

  Reject (`die`) a `--programs` value containing anything other than
  `claude`/`codex`, or an auth-mode value other than `subscription`/
  `api-key`. In `--dry-run`, print the resolved `MANAGED_PROGRAMS`/
  `CLAUDE_AUTH_MODE`/`CODEX_AUTH_MODE` without writing. Otherwise call
  `env_file_set MANAGED_PROGRAMS "..."` and, per selected program,
  `env_file_set CLAUDE_AUTH_MODE "..."` / `env_file_set CODEX_AUTH_MODE "..."`.
  If a program is *not* in `MANAGED_PROGRAMS` on this run but a stale
  `*_AUTH_MODE` key exists in `state/demo.env` from an earlier run, leave
  it in place (harmless - Tasks 3/4 only consult a program's auth mode
  when that program is also in `MANAGED_PROGRAMS`) rather than adding
  deletion logic `env_file_set` doesn't support.

- [ ] **Step 3: Print a summary**

  On success, print each selected program and its resolved mode, e.g.:
  ```
  claude: subscription (sign in with a Claude Team/Enterprise seat)
  codex: api-key (OPENAI_API_KEY from environment)
  ```

- [ ] **Step 4: Run shellcheck and bash -n**

  Run: `shellcheck -x -S warning scripts/15-managed-programs.sh && bash -n scripts/15-managed-programs.sh`
  Expected: no output, exit 0.

- [ ] **Step 5: Exercise all four defaulting paths with `--dry-run`**

  Run each and confirm the printed resolution matches:
  - No env vars set, no flags: both programs, both `subscription`.
  - `ANTHROPIC_API_KEY=x scripts/15-managed-programs.sh --dry-run`: claude
    `api-key`, codex `subscription`.
  - `scripts/15-managed-programs.sh --programs claude --dry-run`: only
    `claude` printed, no `CODEX_AUTH_MODE` mentioned.
  - `scripts/15-managed-programs.sh --programs codex --claude-auth-mode subscription --dry-run`:
    rejected or ignored per Step 1's validation (claude isn't selected, so
    `--claude-auth-mode` is irrelevant) - decide and document whichever
    behavior Step 1 implements; don't leave it unspecified.

- [ ] **Step 6: Run for real and confirm state**

  Run: `scripts/15-managed-programs.sh --programs claude,codex`
  Expected: `state/demo.env` contains `MANAGED_PROGRAMS=claude,codex` plus
  both auth-mode keys, matching the printed summary.

- [ ] **Step 7: Commit**

  ```bash
  git add scripts/15-managed-programs.sh
  git commit -m "Add managed-programs selection and auth-mode resolution"
  ```

## Task 3: `20-controller-up.sh` - version bump and `programs.*` rendering

**Files:**
- Modify: `scripts/20-controller-up.sh:31` (image tag), `scripts/20-controller-up.sh:183-201` (the `daemon.yaml` heredoc)

**Interfaces:**
- Consumes: `MANAGED_PROGRAMS`, `CLAUDE_AUTH_MODE`, `CODEX_AUTH_MODE` from
  `state/demo.env` (Task 2, via the script's existing `load_env_file`
  call).
- Produces: `state/config/daemon.yaml` with conditional `programs.claudeCode`/
  `programs.codex` blocks. Consumed by the controller container at
  runtime (no other task reads this file directly).

- [ ] **Step 1: Bump the default image tag**

  Change line 31 from `image_tag="v0.1.1"` to `image_tag="v0.6.0"`.

- [ ] **Step 2: Build per-program daemon.yaml fragments before the heredoc**

  Before the `cat > "${config_dir}/daemon.yaml"` call, build two
  variables, each empty string if that program isn't in
  `MANAGED_PROGRAMS` (parse the comma list with e.g.
  `[[ ",${MANAGED_PROGRAMS}," == *,claude,* ]]`):
  - `claude_program_block`: if `CLAUDE_AUTH_MODE` is `subscription`:
    ```yaml
      claudeCode:
        companyAnnouncements: ["Managed by AgentDesktop (demo)"]
        auth: subscription
    ```
    if `api-key`:
    ```yaml
      claudeCode:
        companyAnnouncements: ["Managed by AgentDesktop (demo)"]
        useLlmGateway: true
    ```
  - `codex_program_block`: if `CODEX_AUTH_MODE` is `subscription`:
    ```yaml
      codex:
        auth: subscription
    ```
    if `api-key`:
    ```yaml
      codex:
        useLlmGateway: true
    ```
  (Match the existing `programs.claudeDesktop` entry's indentation - two
  spaces under `programs:`.)

- [ ] **Step 3: Switch the heredoc to unquoted and interpolate**

  Change `cat > "${config_dir}/daemon.yaml" <<'EOF'` (quoted, line 183) to
  `cat > "${config_dir}/daemon.yaml" <<EOF` (unquoted, matching
  `controller.yaml`'s heredoc just above it), and replace the static
  `programs:` block (lines 196-200) with:
  ```yaml
  programs:
  ${claude_program_block}${codex_program_block}  claudeDesktop:
    isLocalDevMcpEnabled: true
  EOF
  ```
  Leave `llmGateway`/`telemetry` untouched - `allowedClientIds` already
  lists both `claude-code` and `codex`. If neither program is selected,
  `programs:` renders with only `claudeDesktop:` under it, which is valid
  YAML and matches today's baseline behavior.

- [ ] **Step 4: Run shellcheck and bash -n**

  Run: `shellcheck -x -S warning scripts/20-controller-up.sh && bash -n scripts/20-controller-up.sh`
  Expected: no output, exit 0.

- [ ] **Step 5: Render and inspect without needing Docker**

  Set dummy required env (`OIDC_ISSUER=https://example.test`,
  `OIDC_CLIENT_ID=test-client`), ensure `state/demo.env` has
  `MANAGED_PROGRAMS=claude,codex`, `CLAUDE_AUTH_MODE=subscription`,
  `CODEX_AUTH_MODE=api-key` (from Task 2's Step 6, or set directly), then
  run `scripts/20-controller-up.sh` (it will write
  `state/config/daemon.yaml` before it reaches the Docker-dependent
  steps further down, so letting it fail there is fine for this check).
  Expected: `state/config/daemon.yaml` contains
  `claudeCode:` with `auth: subscription` and `codex:` with
  `useLlmGateway: true`, plus the unchanged `claudeDesktop:` block.
  Re-run with `MANAGED_PROGRAMS=claude` only and confirm `codex:` is
  entirely absent from the file.

- [ ] **Step 6: Commit**

  ```bash
  git add scripts/20-controller-up.sh
  git commit -m "Render managed-program blocks into daemon.yaml, bump controller image"
  ```

## Task 4: `21-agentgateway-up.sh` - per-program auth modes and per-user policy

**Files:**
- Modify: `scripts/21-agentgateway-up.sh` (image tag default at line 25;
  rewrite of the `agentgateway.yaml` rendering block, lines 88-123)

**Interfaces:**
- Consumes: `MANAGED_PROGRAMS`, `CLAUDE_AUTH_MODE`, `CODEX_AUTH_MODE`
  from `state/demo.env`; `ANTHROPIC_API_KEY` env var (required only if
  any selected program's mode is `api-key` and needs it);
  `OPENAI_API_KEY` env var (same, for Codex api-key mode).
- Produces: `state/config/agentgateway.yaml`, consumed by the
  agentgateway container at runtime.

- [ ] **Step 1: Bump the default image tag**

  Change line 25 from
  `image="cr.agentgateway.dev/agentgateway:v1.4.1"` to
  `image="cr.agentgateway.dev/agentgateway:v1.6.0"`.

- [ ] **Step 2: Load managed-program state and validate required keys**

  After `load_env_file`, parse `MANAGED_PROGRAMS` into booleans
  `claude_selected`/`codex_selected` (same comma-list check as Task 3).
  If `claude_selected` and `CLAUDE_AUTH_MODE` is `api-key`, require
  `ANTHROPIC_API_KEY` (reuse the existing
  `: "${ANTHROPIC_API_KEY:?...}"` guard, now conditional rather than
  unconditional). If `codex_selected` and `CODEX_AUTH_MODE` is
  `api-key`, require `OPENAI_API_KEY` the same way. If a program is
  selected in `subscription` mode, no key is required for it.

- [ ] **Step 3: Build one `models:` entry per selected program**

  Keep the existing `jwks_block` logic (lines 60-86) unchanged - it still
  determines how `jwtAuth` fetches its signing keys. Build a `models_block`
  string by concatenating, for each selected program:
  - Claude, `api-key`: today's existing entry, unchanged -
    `- name: "*"` / `provider: anthropic` / `params.apiKey: $ANTHROPIC_API_KEY`.
  - Claude, `subscription`: `- name: "*"` / `provider: anthropic` (no
    `params` - the real credential comes from the `transformations` rule
    in Step 5, not a static key).
  - Codex, `api-key`: `- name: "*"` / `provider: openai` /
    `params.apiKey: $OPENAI_API_KEY`.
  - Codex, `subscription`: `- name: "*"` / `provider: openai` /
    `params.baseUrl: https://chatgpt.com/backend-api/codex`.

  If both programs are selected, at most one of them may legitimately use
  a bare `name: "*"` wildcard model entry (two wildcard entries on one
  listener is a config conflict - the second would never match). Give
  Claude's model entries the name `claude-*` and Codex's `gpt-*` instead
  of `"*"` whenever both are selected (single-program selections may keep
  `"*"` as today). This is the one open algorithmic question in this
  task: confirm during Step 7's manual verification that agentgateway
  actually matches requested model names against these patterns the way
  this assumes - if not, the fallback is giving Claude and Codex separate
  `port:` values under a second `llm:` block instead of sharing one, same
  shape as upstream's own two separate single-program examples, with
  `llmGateway.url` (Task 3) following suit for whichever program the
  daemon.yaml author designates "primary" - note this fallback as a
  follow-up if hit, don't block this task on it speculatively.

- [ ] **Step 4: Build the unified `jwtAuth` block**

  Whenever at least one selected program is in `subscription` mode,
  replace today's plain `jwtAuth` (lines 112-116) with one using this
  exact `location.expression` (handles both a composite
  `agentdesktop:...` bearer and a plain JWT bearer, so it's safe to use
  even when other selected programs are in `api-key` mode):
  ```yaml
      jwtAuth:
        mode: strict
        location:
          expression: |
            request.headers["authorization"].split(" ")[1].with(credential,
              credential.split(":").with(parts,
                parts[0] == "agentdesktop" ? parts[2] : credential
              )
            )
        issuer: agentdesktop-controller
        audiences: [agentgateway]
  ${jwks_block}
  ```
  If *no* selected program is in `subscription` mode, keep today's plain
  `jwtAuth` block (no `location.expression` needed).

- [ ] **Step 5: Add `transformations` for subscription-mode programs**

  For each selected program in `subscription` mode, add a conditional
  transformation that only rewrites the `authorization` header when the
  incoming bearer is a composite one for that program's upstream
  credential (parts[1]), using agentgateway's conditional-policy
  mechanism scoped to that program's model name pattern (`claude-*` /
  `gpt-*`, or the listener's only model if just one program is selected).
  Base the Claude rewrite on:
  ```yaml
      transformations:
        request:
          set:
            authorization: |
              "Bearer " + request.headers["authorization"].split(" ")[1].with(credential,
                credential.split(":").with(parts,
                  parts[0] == "agentdesktop" ? parts[1] : credential
                )
              )
  ```
  and the Codex rewrite additionally setting `chatgpt-account-id` from
  `parts[3]`, per upstream's `examples/codex-subscription/agentgateway.yaml`.
  If only one subscription-mode program is selected, no conditional
  scoping is needed - apply the transformation unconditionally like
  upstream's single-program examples do.

- [ ] **Step 6: Add per-user rate limit and token budget**

  Regardless of mode, add under `llm.policies` (alongside `jwtAuth`):
  ```yaml
      localRateLimit:
      - type: requests
        maxTokens: 20
        tokensPerFill: 20
        fillInterval: 60s
        key: jwt.email
      - type: tokens
        maxTokens: 50000
        tokensPerFill: 50000
        fillInterval: 1h
        key: jwt.email
  ```
  Before wiring `key: jwt.email`, confirm (by inspecting a real
  controller-issued JWT from a running demo, e.g. via
  `curl .../.well-known/jwks.json` plus decoding a token logged by
  `frontendPolicies.logging`) that the claim is actually named `email`;
  if the controller's gateway JWT doesn't carry it, use `key: jwt.sub`
  instead for both rules and note the substitution in the commit message.

- [ ] **Step 7: Run shellcheck, bash -n, and live smoke tests**

  Run: `shellcheck -x -S warning scripts/21-agentgateway-up.sh && bash -n scripts/21-agentgateway-up.sh`
  Then, against a running controller (`20-controller-up.sh` already up),
  exercise these cases, confirming each time that the container starts
  and answers `curl --head http://127.0.0.1:4000/` (the script's own
  existing readiness loop already asserts this, which proves agentgateway
  accepted the composed config - the main risk in Steps 3-5):
  - `MANAGED_PROGRAMS=claude,codex`, `CLAUDE_AUTH_MODE=api-key`,
    `CODEX_AUTH_MODE=subscription`, `ANTHROPIC_API_KEY` exported (mixed
    modes).
  - `MANAGED_PROGRAMS=claude,codex`, both `CLAUDE_AUTH_MODE` and
    `CODEX_AUTH_MODE` set to `subscription`, no keys exported - this is
    the harder case (both composite-bearer listeners sharing one port)
    and the one the open risk in the spec is about; confirm it starts,
    and if agentgateway rejects the composed config, fall back per Step
    3's noted fallback (separate `llm:` blocks/ports) and re-verify.
  - `MANAGED_PROGRAMS=claude` only (proves single-program configs are
    unaffected by the multi-program composition logic).
  - `MANAGED_PROGRAMS=claude,codex`, `CLAUDE_AUTH_MODE=api-key` written
    directly into `state/demo.env` (not via `15-managed-programs.sh` in
    this shell) with `ANTHROPIC_API_KEY` **exported in this shell** but
    *not* re-passed as a flag - confirms Step 2 reads the mode from
    persisted state rather than re-deriving it, which matters for the
    two-machine topology where mode is resolved on one machine and this
    script runs on another.

- [ ] **Step 8: Commit**

  ```bash
  git add scripts/21-agentgateway-up.sh
  git commit -m "Add per-program auth modes and per-user rate limiting to agentgateway"
  ```

## Task 5: `30-daemon-enroll.sh` - user-mode local daemon

**Files:**
- Modify: `scripts/30-daemon-enroll.sh:137` (and the `run-demo.sh`
  `daemon-enroll` manual-step instructions that echo this same command -
  see Task 7)

**Interfaces:**
- No new consumes/produces - this task only changes the printed command
  the operator is told to run.

- [ ] **Step 1: Change the printed enrollment command**

  Change line 137 from
  `    sudo "${install_path}" daemon --config "${bootstrap_path}"`
  to
  `    "${install_path}" daemon --user --config "${bootstrap_path}"`
  and update the surrounding comment/prose (lines 2-7, 133-136) that
  currently describes this as needing `sudo` - the binary install at
  line 111 still uses `sudo install` to place the file in
  `/usr/local/bin`; only the daemon *process* itself drops `sudo` and
  gains `--user`.

- [ ] **Step 2: Run shellcheck and bash -n**

  Run: `shellcheck -x -S warning scripts/30-daemon-enroll.sh && bash -n scripts/30-daemon-enroll.sh`
  Expected: no output, exit 0.

- [ ] **Step 3: Manual check of printed output**

  Run `scripts/30-daemon-enroll.sh --dry-run` and, separately, the
  non-dry-run path against a running controller; confirm the final
  printed command has no `sudo` and includes `--user`.

- [ ] **Step 4: Commit**

  ```bash
  git add scripts/30-daemon-enroll.sh
  git commit -m "Run the local daemon in user mode (subscription auth requires it)"
  ```

## Task 6: `50-validate.sh` - validate managed programs and rate limiting

**Files:**
- Modify: `scripts/50-validate.sh`

**Interfaces:**
- Consumes: `MANAGED_PROGRAMS` from `state/demo.env`.

- [ ] **Step 1: Add a managed-programs check**

  After the existing "Local daemon" check block (around line 106-115),
  add: if `command -v agentdesktop` succeeds, run `agentdesktop status`
  (already captured as `status_output`) and, for each program in
  `MANAGED_PROGRAMS`, `check_pass`/`check_fail` whether that program's
  name appears in the status output as configured/managed. If
  `MANAGED_PROGRAMS` is unset, `check_skip "No managed programs recorded (15-managed-programs.sh not run)"`.

- [ ] **Step 2: Add a rate-limit smoke check**

  New check block: if agentgateway is reachable (reuse the existing
  "agentgateway reachability" check's result), fire 25 rapid
  unauthenticated `HEAD /` requests (reusing the same reachability route
  the existing check already uses) and confirm at least one comes back
  `429` - this exercises the `localRateLimit` requests rule from Task 4
  Step 6 without needing a real JWT. `check_pass` if a 429 appears,
  `check_fail` with the observed status codes if not, `check_skip` if
  agentgateway isn't reachable.

- [ ] **Step 3: Run shellcheck and bash -n**

  Run: `shellcheck -x -S warning scripts/50-validate.sh && bash -n scripts/50-validate.sh`
  Expected: no output, exit 0.

- [ ] **Step 4: Run against a live demo and confirm both new checks report**

  Run `scripts/50-validate.sh` against a fully running demo (controller +
  agentgateway + enrolled daemon) and confirm the new checks appear in
  the summary with a `pass`/`fail`/`skip` outcome, not a script crash.

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/50-validate.sh
  git commit -m "Validate managed programs and per-user rate limiting"
  ```

## Task 7: `run-demo.sh` - wire the new step and program/mode prompts

**Files:**
- Modify: `run-demo.sh` (new wizard step between `controller-address`/
  `pilot-user` and `controller-up`; replace the `agentgateway-up` block's
  ad hoc `ANTHROPIC_API_KEY`-only prompt; update the `daemon-enroll`
  manual-step instructions to match Task 5)

**Interfaces:**
- Consumes: Task 2's `scripts/15-managed-programs.sh` flags.

- [ ] **Step 1: Add the `managed-programs` wizard step**

  Insert a new `section`/prompt block before `skip_until controller-up`
  (after the existing `entra-consent`/`intune-licensing` steps), modeled
  on the existing `pilot-user` block's pattern of gum-prompting then
  calling the underlying script with explicit flags:
  - `gum choose` (multi-select if gum supports it here, else two
    `gum confirm` prompts) for which of Claude Code / Codex to manage,
    defaulting to both.
  - For each selected program, `gum confirm "Use a real <Claude
    Team/Enterprise seat|ChatGPT account> instead of an API key?"
    --default=true`; if declined, prompt for the key with
    `gum input --password` (reusing the existing pattern at the
    `agentgateway-up` block) and `export` it rather than persisting it.
  - Call `run_auto managed-programs "Managed programs" "..." --
    "${SCRIPTS_DIR}/15-managed-programs.sh" --programs "${selected}"
    [--claude-auth-mode ... ] [--codex-auth-mode ...]`.

- [ ] **Step 2: Simplify the `agentgateway-up` block**

  Remove the now-redundant standalone `ANTHROPIC_API_KEY` prompt inside
  the existing `agentgateway-up` section (it's superseded by Step 1's
  per-program key prompts) - keep the `gum confirm "Include live Claude
  Code traffic through agentgateway?"` framing only if at least one
  selected program is in `api-key` mode and still needs its key exported
  at this point in the flow; otherwise this section just runs
  `21-agentgateway-up.sh` directly.

- [ ] **Step 3: Update the `daemon-enroll` manual-step text**

  Match Task 5's change: remove `sudo` from the printed command shown at
  the `daemon-enroll` manual step, add `--user`. Additionally, append a
  line to that same manual step's instructions: for any selected program
  in `subscription` mode, once the daemon is running and enrolled, sign
  into Claude.ai and/or ChatGPT in a browser when agentdesktop's
  checklist/UI prompts for it (reference the design doc's "new manual
  demo step") - this is the only place in the wizard that step belongs,
  since it happens after the same daemon-enroll action and needs the
  operator's live attention the same way the Entra ID sign-in does.

- [ ] **Step 4: Run shellcheck and bash -n**

  Run: `shellcheck -x -S warning run-demo.sh && bash -n run-demo.sh`
  Expected: no output, exit 0.

- [ ] **Step 5: Walk through the wizard interactively**

  Run `./run-demo.sh` end to end (or `--from managed-programs` to jump
  there) and confirm the new step prompts sensibly, persists state, and
  the rest of the wizard proceeds using it.

- [ ] **Step 6: Commit**

  ```bash
  git add run-demo.sh
  git commit -m "Wire managed-programs selection into the wizard"
  ```

## Task 8: README updates

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update prerequisites**

  Change the `ANTHROPIC_API_KEY` bullet to describe it as optional
  (only needed for API-key mode), and add: a Claude Team/Enterprise seat
  and/or a ChatGPT account, needed for subscription mode (the default);
  Codex CLI (>= 0.153.4) and/or Claude Code installed on the pilot Mac,
  per whichever programs are selected.

- [ ] **Step 2: Document `--programs` and auth-mode flags**

  Add a short subsection (near "Advance Installation") describing
  `15-managed-programs.sh --programs claude,codex [--claude-auth-mode ...] [--codex-auth-mode ...]`
  and the new `managed-programs` step id in the `--from STEP_ID` list.

- [ ] **Step 3: Note the new manual sign-in step for subscription mode**

  Add a sentence near "What gets created" describing that, in
  subscription mode, the pilot operator signs into Claude.ai/ChatGPT in a
  browser after the daemon applies its configuration.

- [ ] **Step 4: Review for stale claims**

  Confirm nothing in the file still implies `programs.claudeCode`/
  `programs.codex` are companyAnnouncement-only or that Claude Code is
  the only managed program.

- [ ] **Step 5: Commit**

  ```bash
  git add README.md
  git commit -m "Document managed-programs selection and subscription auth"
  ```
