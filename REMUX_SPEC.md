# remux — Product & Engineering Spec

> remux = cmux, reimagined around **remote servers** with a **Termius feel**: save servers, click to connect, jump into tmux sessions on any host, pin a server+session as a workspace — and (phase 3) host a live session your team/fam can join and work in *together* on one server, no commits, no pushing.

Status: **Draft v1** · Base: fork of [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux) · Target: native macOS (Swift/Xcode, Ghostty terminal)

---

## 1. The core insight

cmux **already ships the hard parts**. A 4-agent architecture sweep of this codebase found:

- A full **remote-session layer** — `WorkspaceRemoteConfiguration` (ssh **and** websocket transport, destination, port, identity, relay tokens, *persistent daemon slots*), `RemoteSessionCoordinator`, `WorkspaceRemoteConnectionState`. SSH runs via the native `ssh` binary; there's an `ssh://` URL scheme + `cmux ssh` CLI.
- **Mature tmux integration** — `RemoteTmuxSSHTransport` (lists sessions via `tmux list-sessions -F`), `RemoteTmuxControlConnection` (live `tmux -CC` control-mode attach), and socket RPCs `remote.tmux.sessions / attach / mirror / window / detach`. `cmux ssh-tmux <host>` already opens a window mirroring a host's tmux sessions as tabs, handling password/MFA/host-key prompts.
- **Session persistence** — JSON snapshots (`SessionWorkspaceSnapshot` → `SessionPanelSnapshot`), and `SessionTerminalPanelSnapshot.remotePTYSessionID` **already exists** to persist a remote tmux attachment.
- A **built-in browser** — browser panes, omnibar, profile import (your "need a browser to test things on the server" is already done).

**What's genuinely missing** is the Termius product layer: there is **no saved-server library / persistence** (connections are ad-hoc), no click-to-connect GUI, no "save this server+session as a workspace" affordance, and no invite/host flow for collaboration.

### The collaboration reframe (most important decision in this spec)

Building networked collaborative editing *inside* cmux is a 12–16 week monster: the control socket is **local Unix-domain only**, stateless request/response (no broadcast), and a PTY is 1:1 with a surface. **We will not do that.**

Instead we lean on the fact that **tmux is already multiplayer**: multiple clients attaching to the *same* tmux session see and control the *same* live terminal. cmux already speaks `tmux -CC attach`. So "you're all remuxed into one server, working live" = everyone SSHes to one host and attaches the same tmux session. remux's job is the **invite + auto-attach UX + scoped access**, not CRDTs. Weeks, not quarters.

---

## 2. Gap analysis

| Your vision | cmux today | remux work |
|---|---|---|
| Save servers, click to connect (Termius feel) | Ad-hoc only (`cmux ssh`, `ssh://`) — **no store, no UI** | **Build**: server store + library sidebar + connect wiring |
| Hit tmux sessions on any server, list + attach | ✅ `remote.tmux.sessions` / `attach` / `mirror`, `cmux ssh-tmux` | **Surface** in the new GUI; small glue |
| Pin a server+session as a saved workspace | Partial — snapshots persist `remotePTYSessionID`, mirror creates tabs | **Build**: "Save as Workspace" + rehydrate-on-open |
| Live collab: team/fam in one server, no commits | ❌ not as a product flow (but tmux makes it native) | **Build**: host + invite + scoped-access + auto-attach |
| Browser to test on the server | ✅ built-in browser panes + omnibar | none |
| Not from scratch | ✅ full cmux clone, history intact | rebrand only |

---

## 3. Phased plan

### Phase 0 — Rebrand cmux → remux  *(~2–4 days)*
Make it *yours* before adding features, so the app you build/run says remux.

- Xcode project: app display name, scheme, bundle id (`com.…/remux`), `.xcode-version` stays.
- `Info.plist`, `cmux.entitlements` / `cmux-helper.entitlements` (also affects URL scheme — register `remux://` alongside/instead of `cmux://` / `ssh://`).
- `AppIcon.icon` / `Assets.xcassets` — new icon.
- Window/menu titles, "About" strings, user-facing copy.
- Decide CLI name: keep `cmux` binary internally or alias `remux`? (The bundled CLI is wired via `CMUX_BUNDLED_CLI_PATH`; renaming touches many env-var call sites — recommend **keep internal `cmux` socket/env names, rebrand only user-facing surfaces** in phase 0 to avoid a giant churny diff. Full env rename can be a later cleanup.)
- Build/run unchanged: `./scripts/setup.sh` then `./scripts/reload.sh --tag <slug> --launch`. **Never bare `xcodebuild`/untagged `open`** (per CLAUDE.md — shared default socket/bundle id steals focus / conflicts).

> ⚠️ Open decision: how thorough a rebrand for v1? Recommend **surface-only** (name/icon/titles/URL scheme), defer internal `CMUX_*` renames.

### Phase 1 — Server Library (the Termius layer)  *(~1.5–2.5 weeks)*
**Goal:** a saved list of servers; click one to connect; smooth.

- **Data model** — new `SavedServer` struct: `id`, `nickname`, `WorkspaceRemoteConfiguration` (reuse existing!), optional `group/folder`, `lastConnectedAt`, `color/icon`. Persist to `~/Library/Application Support/cmux/servers.json` via the existing `SessionSnapshotRepository`/`CmuxSettings` patterns (JSON, atomic write, `.sortedKeys`).
- **Store** — `ServerLibraryStore` (ObservableObject): CRUD + ordering + groups.
- **UI** — add a `.servers` mode to `RightSidebarMode` (`Sources/ContentView+RightSidebarCommandPalette.swift`) **or** a "Servers" section in the workspace sidebar (`Sources/SidebarWorkspaceGroupHeaderView.swift`). Termius-style list: nickname, host, status dot, connect on click; add/edit/delete sheet.
- **Connect wiring** — on click, build `WorkspaceRemoteConfiguration` from the saved server and call the existing remote-connect path (`Workspace.configureRemoteConnection(_:autoConnect:)`) / route through the same code `cmux ssh` uses. Reuse `RemoteSessionCoordinator`, interactive-auth path (`runInteractiveAuthSSH`) for password/MFA.
- **Command palette** — `palette.connectToServer` action (fuzzy over saved servers) for keyboard-first connect.

**Files:** `Sources/ContentView+RightSidebarCommandPalette.swift`, `Sources/SidebarWorkspaceGroupHeaderView.swift`, `Packages/macOS/CmuxSettings/…`, `Sources/Workspace.swift` (configureRemoteConnection), `Packages/macOS/CmuxRemoteSession/…`.

### Phase 2 — Session-as-Workspace  *(~1–2 weeks)*
**Goal:** open a server, see its tmux sessions, attach one, and **save that server+session as a named workspace** you reopen into instantly.

- **List + attach** — surface `remote.tmux.sessions` in the connect flow (a session picker after connecting); attach via `remote.tmux.attach` / the `cmux ssh-tmux` mirror path. (Engine exists; this is GUI + glue.)
- **Save as Workspace** — extend the saved-workspace snapshot to record `{ serverId, tmuxSessionName }`. `SessionTerminalPanelSnapshot.remotePTYSessionID` already persists the attachment id; add the human-meaningful `tmuxSessionName` + link to `SavedServer`.
- **Rehydrate on open** — opening the saved workspace: auto-connect the server (Phase 1 path) → `tmux attach -t <name>` (create-if-missing optional) → restore layout. Reuse restore flow at `Workspace.restoreSessionSnapshot`.
- **(Optional)** new `PanelType.remoteTmuxSession` + `SurfaceKind` if we want a first-class non-terminal surface; **recommend NOT** for v1 — a terminal panel carrying remote config is enough and far less code.

**Files:** `Sources/SessionPersistence.swift` (snapshot structs ~1414+), `Sources/Workspace.swift` (restore ~153, factories ~6999), `Sources/TerminalController+RemoteTmux.swift`, `Sources/RemoteTmuxController.swift`.

### Phase 3 — Live collaboration ("remux into one server together")  *(~2–4 weeks)*
**Goal:** host a session; your team/fam joins; everyone in the same live shell on one server. **Mechanism = shared tmux session over SSH**, not in-app networking.

- **Host** — pick a reachable server + a tmux session to share. Reachability: prefer the existing **Tailscale-addressable device registry** (`remotes.*` RPCs, `Cloud/VMClient.swift`) so no manual port-forwarding; fallback to a normal SSH host the guests can already reach.
- **Invite** — generate a `remux://join?...` link (or short code) encoding host + session + scoped credential. Registering the URL scheme is part of Phase 0.
- **Scoped guest access** — the hard/sensitive bit. Options, roughly increasing effort/safety:
  1. **Shared key / existing accounts** (v1, simplest): guests already have SSH access to the host; invite just carries host+session and auto-runs `tmux attach -t <name>`.
  2. **Per-invite throwaway principal** — provision a restricted user / `authorized_keys` entry (`command="tmux attach -t <name>"`, `restrict`) on the host, revocable. Best safety/effort tradeoff.
  3. **Relay through host identity** — leverage existing relay/`persistentDaemonSlot` infra so guests never get raw shell. Most work.
- **Guest UX** — clicking the invite: confirm dialog → connect → auto-attach → you're in the same terminal, live. (This is just Phase 1+2 paths triggered by a URL.)
- **Niceties (later):** read-only mode (`tmux attach -r`), per-cursor identity isn't native to tmux (shared cursor) — set expectations: it's *shared control*, like classic tmux pairing.

> ⚠️ Open decisions: (a) which guest-access model for v1 — recommend **#1 for demo, #2 for real**; (b) do guests need remux installed, or support a plain-`ssh` fallback join?

**Files:** `Sources/AppDelegate+CmuxSSHURL.swift` (URL handling), `Sources/Cloud/VMClient.swift` + `remotes.*` RPC handlers (reachability/registry), Phase 1/2 connect+attach paths.

---

## 4. Suggested build order & milestones

1. **M0** — Phase 0 rebrand; app builds & launches as "remux". *Proves the fork + build loop.*
2. **M1** — Phase 1 server library; save a server, click, connect. *First real Termius moment.*
3. **M2** — Phase 2 attach a tmux session + Save as Workspace + reopen. *Core differentiator done.*
4. **M3** — Phase 3 invite a second person to a shared session (model #1). *The "send it to my fam" demo.*
5. **M4** — hardening: scoped access (#2), read-only, groups/search, polish.

Rough total to a compelling demo (M0–M3): **~5–8 weeks**; production-ready collab adds more.

---

## 5. Risks & watch-items

- **Build discipline** — always `reload.sh --tag <slug>`; untagged builds share default socket/bundle id and conflict (per CLAUDE.md). Multiple agents building simultaneously must use distinct tags.
- **Rebrand churn** — full `CMUX_*` env/socket rename touches huge surface area. Keep internal names; rebrand UI only for v1.
- **Collab security** — phase 3 guest access grants shell on a real server. Don't ship model #1 beyond trusted demos; gate real use behind model #2 (restricted, revocable principals).
- **Upstream drift** — this is a fork of an active repo. Decide now: track upstream `manaflow-ai/cmux` (rebase periodically) or hard-fork. Recommend **track upstream** early — they're already building toward remote tmux, so we may get features for free.
- **tmux assumptions** — collab + session-as-workspace assume tmux on the host. Detect & guide when absent (engine already classifies "no server running").

---

## 6. Open questions for Myles

1. **Rebrand depth (v1):** surface-only (name/icon/titles/URL scheme) vs. full internal rename? *(recommend surface-only)*
2. **Collab guest access (v1):** shared-existing-access (#1, demo) vs. restricted per-invite principal (#2, real)? *(recommend #1 to demo, #2 to ship)*
3. **Upstream:** track `manaflow-ai/cmux` and rebase, or hard-fork? *(recommend track)*
4. **Guests need remux installed,** or support plain-`ssh` join fallback?
5. **Scope of v1 demo** — is the goal a working M3 demo to show your fam, or a polished M4?
