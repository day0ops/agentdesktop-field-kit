# Intune Notarized-PKG Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Intune raw-binary/shell-script workaround with native macOS PKG app deployment of agentdesktop's own notarized installer, running the daemon as a user-mode LaunchAgent for the console user instead of a system LaunchDaemon.

**Architecture:** `41-intune-push.sh` pushes agentdesktop's notarized `.pkg` as an Intune macOS line-of-business app (the binary-install concern). `lib/upsert-intune-script.sh` is kept but narrowed to a companion deviceShellScript whose only job is writing the rendered config/CA to disk and bootstrapping a user-mode LaunchAgent for the console user (the config-delivery concern) - both assigned to the same pilot group so they land together on the device.

**Tech Stack:** Bash, Microsoft Graph API (`deviceManagement/mobileApps`, `deviceShellScripts`), `az rest`/`curl` (existing `graph_call` pattern), macOS `launchctl`/LaunchAgent plist.

**Spec:** `docs/superpowers/specs/2026-11-10-latest-agentdesktop-managed-programs-design.md`

**Depends on:** `docs/superpowers/plans/2026-11-10-agentdesktop-managed-programs-plan.md` - specifically its `MANAGED_PROGRAMS`/`CLAUDE_AUTH_MODE`/`CODEX_AUTH_MODE` state keys (Task 2 there) and the user-mode daemon convention (Task 5 there). That plan should land first; this one reuses its rendered `state/config/daemon.yaml`/`agentgateway.yaml` outputs without changing them further.

## Global Constraints

- The notarized `.pkg` assets are `agentdesktop-macos-{arm64,amd64}.pkg`
  (confirmed present from `v0.3.0` onward), checksum-verified the same
  way `41-intune-push.sh` already verifies raw binaries today (fetch
  `.sha256`, compare before trusting the artifact).
- `lib/upsert-intune-script.sh` is modified, not deleted or replaced
  wholesale - its `graph_call`/licensing-check/idempotent-upsert
  machinery is reused for the new, smaller companion script.
- The daemon runs as a **user-mode LaunchAgent** for whichever user is on
  console, matching the existing console-user-detection logic already in
  `41-intune-push.sh` (today used only to manage group membership).
- Every modified or new script keeps `--dry-run`/`--help`.

## Review Focus

- **No user logged into the console when the companion script runs** (the
  PKG's `postinstall`/the shell script runs as root via Intune regardless
  of login state): the LaunchAgent bootstrap must not crash or hang
  waiting for a console user - it should detect "no real user" (reusing
  the existing `console_user` case match for `""|root|loginwindow|_mbsetupuser`)
  and skip the `launchctl bootstrap gui/<uid>` step, same as today's
  group-membership logic already skips in that case.
- **Re-running the companion script after the PKG already installed the
  app and the LaunchAgent is already loaded:** must be idempotent - same
  `changed` tracking pattern as today's shell script, not an unconditional
  `launchctl bootstrap` that errors on an already-loaded label.
- **The PKG app and the companion script land on the device in the wrong
  order** (companion script runs before the PKG has installed the app
  bundle its LaunchAgent plist points at): the companion script should
  fail loudly if the expected installed binary/app path doesn't exist
  yet, not silently write a LaunchAgent plist pointing at nothing and
  report success.
- **A pilot Mac with an existing system LaunchDaemon from a prior run of
  the old (pre-this-plan) field kit:** the companion script should detect
  and remove/boot out the stale system LaunchDaemon before bootstrapping
  the new user-mode LaunchAgent, so the two don't both try to run the
  daemon at once.
- **Graph token/licensing failures specific to the new app type**
  (`deviceManagement/mobileApps` may need a different permission than
  `DeviceManagementScripts.ReadWrite.All`): confirm the required Graph
  permission for creating a `macOSPkgApp` before assuming today's
  `lib/get-graph-app-token.sh` setup covers it unchanged.

---

## Task 1: Research the Graph API shape for a macOS PKG LOB app

**Files:** none (research task; its output is the exact payload Task 2
needs)

- [ ] **Step 1: Confirm the required Graph permission**

  Check Microsoft Graph's documentation (or a scratch `az rest` call
  against a test tenant) for what application permission
  `deviceAppManagement/mobileApps` with `@odata.type:
  "#microsoft.graph.macOSPkgApp"` requires to create/update/assign. If it
  differs from `DeviceManagementScripts.ReadWrite.All`
  (`lib/get-graph-app-token.sh`'s current `permission_value`), note the
  correct value(s) - likely `DeviceManagementApps.ReadWrite.All`.

- [ ] **Step 2: Confirm the content-upload flow**

  Unlike `deviceShellScripts` (whose `scriptContent` is inline base64 in
  one POST body), Graph's mobile LOB app content upload is a multi-step
  flow: create the app metadata, create a `contentVersions` entry, get an
  Azure Storage SAS URI, upload the PKG bytes to that URI in chunks,
  commit the content version, then set `committedContentVersion` on the
  app. Confirm the exact endpoint sequence and required fields
  (`fileEncryptionInfo`, chunk size limits) against Graph's current beta
  docs before Task 2 is written in detail - this plan deliberately
  doesn't guess the exact request bodies.

- [ ] **Step 3: Write up findings**

  Record the confirmed permission name and endpoint sequence as a
  short comment block atop the new file from Task 2, so the
  implementation is traceable to what was actually verified rather than
  assumed.

## Task 2: `lib/upsert-intune-pkg-app.sh` - push the notarized PKG as a native app

**Files:**
- Create: `lib/upsert-intune-pkg-app.sh` (new sibling to
  `lib/upsert-intune-script.sh`, same `graph_call`/licensing-check
  pattern copied in, not abstracted into a shared file - this repo
  doesn't currently factor shared Graph helpers out of each `lib/*.sh`,
  and introducing that abstraction isn't required by this task)

**Interfaces:**
- Consumes: a local `.pkg` file path, a group ID, a display name
  (CLI args, mirroring `lib/upsert-intune-script.sh`'s signature:
  `upsert-intune-pkg-app.sh PKG_FILE GROUP_ID [--display-name NAME] [--dry-run]`).
- Produces: nothing other tasks consume programmatically; it's invoked by
  Task 4 the same way `41-intune-push.sh` invokes
  `lib/upsert-intune-script.sh` today.

- [ ] **Step 1: Write argument parsing and the licensing/auth checks**

  Copy `lib/upsert-intune-script.sh`'s `usage()`, arg-parsing loop, and
  the tenant-Intune-licensing check (its lines 143-167) verbatim - same
  preconditions apply. Update `graph_call`'s `GRAPH_BEARER_TOKEN` comment
  to reference whichever permission Task 1 confirmed, and update
  `lib/get-graph-app-token.sh`'s `permission_value` if Task 1 found it
  needs to request a second/different app role (see that script's
  `required_resource_accesses` - this may need a second role entry rather
  than a replacement, if `deviceShellScripts` and `macOSPkgApp` use
  different permissions and the companion script in Task 3 still needs
  the original one).

- [ ] **Step 2: Implement the create-or-update-and-assign flow**

  Using the endpoint sequence Task 1 confirmed: create or find-and-update
  the `macOSPkgApp` metadata (matched by `displayName`, same
  "more than one match is ambiguous, refuse" guard as
  `lib/upsert-intune-script.sh` lines 199-202), upload the PKG content via
  the confirmed chunked-upload flow, commit it, then `POST .../assign`
  with the same `mobileAppAssignments` shape pointed at `GROUP_ID`
  (install intent `required`, matching this kit's push-to-pilot-group
  pattern elsewhere).

- [ ] **Step 3: Implement `--dry-run`**

  Print the resolved display name, group ID, PKG file size/checksum, and
  endpoint sequence that would run, without calling Graph - mirror
  `lib/upsert-intune-script.sh`'s dry-run block shape.

- [ ] **Step 4: Run shellcheck and bash -n**

  Run: `shellcheck -x -S warning lib/upsert-intune-pkg-app.sh && bash -n lib/upsert-intune-pkg-app.sh`
  Expected: no output, exit 0.

- [ ] **Step 5: Exercise against a real test tenant**

  Run with `--dry-run` first and confirm the printed plan looks right,
  then for real against a test Intune tenant with a downloaded
  `agentdesktop-macos-arm64.pkg`; confirm the app appears in
  `https://intune.microsoft.com` under Apps > macOS, assigned to the
  target group. Re-run and confirm it updates rather than duplicating.

- [ ] **Step 6: Commit**

  ```bash
  git add lib/upsert-intune-pkg-app.sh
  git commit -m "Add Intune macOS PKG line-of-business app upsert helper"
  ```

## Task 3: Narrow `lib/upsert-intune-script.sh`'s companion script to config/LaunchAgent only

**Files:**
- Modify: `lib/upsert-intune-script.sh` (no signature change - still
  takes a script file + group ID; only the *content* of the script
  Task 4 hands it changes)

**Interfaces:**
- No change to this file's own interface; Task 4 is the one that stops
  generating a binary-installing script and starts generating this
  narrower one.

- [ ] **Step 1: Confirm no change is actually needed here**

  Re-read `lib/upsert-intune-script.sh` end to end: it already just takes
  *a* script file and pushes it as a `deviceShellScript` - it has no
  binary-install-specific logic of its own (that all lives in the
  rendered script content, which Task 4 owns). Expect this task to
  produce **no diff** to this file; if review turns up something
  binary-install-specific baked into this file itself (e.g. a
  description string referencing "installs the agentdesktop daemon" at
  line 108 that should be reworded now that the PKG does the install),
  fix only that.

- [ ] **Step 2: Update the hardcoded description string if found**

  Line 108's `description` argument to the Graph payload currently reads
  "Installs the agentdesktop daemon and writes its controller bootstrap
  and public trust root." - update to "Writes the agentdesktop controller
  bootstrap config and public trust root, and loads the daemon as a user
  LaunchAgent." (the PKG now owns installing the daemon itself).

- [ ] **Step 3: Run shellcheck and bash -n**

  Run: `shellcheck -x -S warning lib/upsert-intune-script.sh && bash -n lib/upsert-intune-script.sh`
  Expected: no output, exit 0.

- [ ] **Step 4: Commit**

  ```bash
  git add lib/upsert-intune-script.sh
  git commit -m "Describe the companion Intune script as config/LaunchAgent-only"
  ```

## Task 4: Rewrite `41-intune-push.sh` to push both pieces

**Files:**
- Modify: `scripts/41-intune-push.sh` (substantial rewrite of the asset
  resolution, rendered-script content, and push calls)

**Interfaces:**
- Consumes: `lib/upsert-intune-pkg-app.sh` (Task 2), the narrowed
  `lib/upsert-intune-script.sh` (Task 3), `INTUNE_PILOT_GROUP_ID` from
  `state/demo.env` (unchanged from today).
- Produces: nothing new other tasks consume.

- [ ] **Step 1: Resolve the PKG asset instead of the raw binary**

  Replace the `fetch_hash`/`sha_arm64`/`sha_amd64` logic (lines 60-72,
  which resolves `agentdesktop-darwin-{arm64,amd64}` and their
  `.sha256`s) with the same pattern resolving
  `agentdesktop-macos-{arm64,amd64}.pkg` and their `.sha256`s instead.
  Download the architecture-appropriate `.pkg` to `${generated_dir}`
  (both architectures, or just build the PKG push to let Intune's own
  universal/architecture handling apply - confirm during Task 1/2 whether
  agentdesktop ships one universal `.pkg` or arch-specific ones; the
  release asset names found during the spec's research were
  arch-specific, so expect to push both and let Intune's app
  "applicability" rules pick per device, matching how Intune normally
  handles arch-specific macOS LOB apps).

- [ ] **Step 2: Shrink the rendered companion script**

  Replace the `SCRIPT_HEADER` heredoc (lines 90-212) - which today
  downloads/installs the binary, creates the `agentdesktop` group, and
  writes a **system** LaunchDaemon plist - with a smaller script that:
  - Skips binary download/install entirely (the PKG, pushed by Task 2,
    owns this) but **fails loudly** (per this plan's Review Focus) if
    the expected installed path (confirm the PKG's actual install
    location - likely `/Applications/agentdesktop.app` or
    `/usr/local/bin/agentdesktop`, per Task 1's research) doesn't exist.
  - Keeps the `agentdesktop` group creation and console-user group
    membership logic (lines 137-139, 203-211) unchanged - still needed
    regardless of install mechanism.
  - Keeps `write_managed_file` and the `config.yaml`/CA rendering (lines
    141-169) unchanged in content, but writes the LaunchAgent plist
    (replacing lines 171-195) with `RunAtLoad`/`KeepAlive` as today, a
    `ProgramArguments` array adding `--user` after `daemon` (matching
    Task 5 of the managed-programs plan), and - this is the key
    structural change - targets
    `/Library/LaunchAgents/dev.agentdesktop.daemon.plist` instead of
    `/Library/LaunchDaemons/...`.
  - Before bootstrapping, detects and removes any stale **system**
    LaunchDaemon from a prior run (per this plan's Review Focus):
    `/bin/launchctl bootout system/dev.agentdesktop.daemon >/dev/null 2>&1 || true`
    and `/bin/rm -f /Library/LaunchDaemons/dev.agentdesktop.daemon.plist`
    before writing the new LaunchAgent.
  - Loads the LaunchAgent for the console user with
    `/bin/launchctl bootout gui/"${console_uid}" "${PLIST_PATH}" >/dev/null 2>&1 || true`
    then `/bin/launchctl bootstrap gui/"${console_uid}" "${PLIST_PATH}"`
    then `/bin/launchctl kickstart -k "gui/${console_uid}/${LABEL}"`,
    guarded by the same "no real console user" skip the group-membership
    logic already does (reuse that `case` block's condition rather than
    duplicating a second check).

- [ ] **Step 3: Replace the two push calls at the bottom**

  Replace the single `bash "${FIELD_KIT_ROOT}/lib/upsert-intune-script.sh" "${bootstrap_script}" "${group_id}" --display-name "agentdesktop bootstrap"`
  call with two: Task 2's `lib/upsert-intune-pkg-app.sh` for the
  downloaded `.pkg` (display name e.g. "agentdesktop") and the existing
  `lib/upsert-intune-script.sh` call (display name unchanged,
  "agentdesktop bootstrap") for the shrunk companion script from Step 2 -
  both assigned to `${group_id}`.

- [ ] **Step 4: Update `--dry-run` output**

  Reflect both pushes (PKG app + companion script) in the `--dry-run`
  block (currently lines 78-87), matching the format each
  `lib/upsert-intune-*.sh` helper already prints in its own `--dry-run`.

- [ ] **Step 5: Run shellcheck and bash -n**

  Run: `shellcheck -x -S warning scripts/41-intune-push.sh && bash -n scripts/41-intune-push.sh`
  Expected: no output, exit 0.

- [ ] **Step 6: Exercise against a real test tenant and pilot Mac**

  Run `scripts/41-intune-push.sh --dry-run` first, then for real. On the
  pilot Mac, force an Intune check-in (per the script's existing
  `log_warn` instructions) and confirm: the PKG app installs, the
  companion script runs, `launchctl print gui/$(id -u <consoleuser>)/dev.agentdesktop.daemon`
  shows it loaded, and no `system/dev.agentdesktop.daemon` LaunchDaemon
  remains loaded. Force a second check-in (re-running the same companion
  script) and confirm it reports no changes and doesn't error on an
  already-loaded LaunchAgent. Separately, on a pilot Mac still carrying a
  system LaunchDaemon from a pre-this-plan run of the kit, confirm the
  companion script's run bootouts/removes it before the new LaunchAgent
  loads.

- [ ] **Step 7: Commit**

  ```bash
  git add scripts/41-intune-push.sh
  git commit -m "Push the notarized PKG and a user-mode LaunchAgent via Intune"
  ```

## Task 5: `90-teardown.sh` and `50-validate.sh` - unload the LaunchAgent instead of the LaunchDaemon

**Files:**
- Modify: `scripts/50-validate.sh:117-121`
- Modify: `scripts/90-teardown.sh:53-56`

**Interfaces:** none beyond what Task 4 of the managed-programs plan
already added.

- [ ] **Step 1: Replace the validate check**

  Change the `launchctl print system/dev.agentdesktop.daemon` check to
  instead check `launchctl print gui/$(id -u "$(stat -f '%Su' /dev/console)")/dev.agentdesktop.daemon`
  (reuse this kit's existing console-user detection idiom), with the same
  `check_pass`/`check_skip` shape - skip (not fail) when no console user
  is logged in, same reasoning as the companion script's own skip
  condition.

- [ ] **Step 2: Replace the teardown unload logic**

  Change `scripts/90-teardown.sh:53-56`'s `plist_path`/`launchctl print
  system/...`/`sudo launchctl bootout system/...` to the
  `gui/<console-uid>` equivalent and
  `/Library/LaunchAgents/dev.agentdesktop.daemon.plist`, dropping `sudo`
  from the `bootout` call (a user-mode LaunchAgent doesn't need root to
  unload) - same console-user idiom as Step 1. Also remove the plist file
  itself (`rm -f "${plist_path}"`) if `90-teardown.sh` doesn't already do
  so elsewhere - confirm by reading the surrounding lines before adding a
  second removal.

- [ ] **Step 3: Run shellcheck and bash -n on both files**

  Run: `shellcheck -x -S warning scripts/50-validate.sh scripts/90-teardown.sh && bash -n scripts/50-validate.sh scripts/90-teardown.sh`
  Expected: no output, exit 0.

- [ ] **Step 4: Run both against a device with the new LaunchAgent loaded**

  Confirm `50-validate.sh` reports `pass` on a pilot Mac after Task 4's
  push has landed and the console user is logged in; confirm
  `90-teardown.sh` unloads it and `launchctl print gui/<uid>/dev.agentdesktop.daemon`
  then fails (expected, since it's unloaded).

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/50-validate.sh scripts/90-teardown.sh
  git commit -m "Validate and tear down the user-mode LaunchAgent instead of the system LaunchDaemon"
  ```

## Task 6: README updates

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Remove the workaround framing**

  Remove/rewrite the "What gets created" bullet describing Intune
  delivery as "a shell script (not a signed/notarized PKG - we don't have
  a notarization identity for a same-day pilot)" - replace with: a native
  macOS PKG app (agentdesktop's own notarized installer) plus a small
  companion script that writes config/CA and loads the daemon as a
  user-mode LaunchAgent for the console user.

- [ ] **Step 2: Commit**

  ```bash
  git add README.md
  git commit -m "Document native PKG Intune deployment"
  ```
