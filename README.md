<h1 align="center">remux</h1>
<p align="center">A native macOS app for living across remote servers — the smoothness of a great SSH/SFTP client, reimagined for how people actually work today.</p>

<p align="center">
  <a href="https://github.com/mylesndavid/remux/releases/latest"><img src="https://img.shields.io/github/v/release/mylesndavid/remux?label=download&color=4c71f2" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon-555?logo=apple" alt="macOS Apple Silicon" />
  <img src="https://img.shields.io/badge/license-GPL--3.0-555" alt="GPL-3.0" />
</p>

## Install

Paste this into Terminal — it downloads remux, drops it in **/Applications**, and opens it:

```bash
curl -fsSL https://github.com/mylesndavid/remux/releases/latest/download/remux-macos.zip -o /tmp/remux.zip && ditto -xk /tmp/remux.zip /Applications/ && xattr -dr com.apple.quarantine /Applications/remux.app && open /Applications/remux.app
```

> Currently an **unsigned, Apple Silicon** build — the installer clears the macOS quarantine flag so it opens without the Gatekeeper warning. A notarized build (and Intel/universal) are on the way. remux **auto-updates** itself via Sparkle once installed.

You can also grab the zip from the [**latest release**](https://github.com/mylesndavid/remux/releases/latest).

## What remux does

remux turns remote servers into first-class, persistent workspaces:

- **Server Library** — save servers and click to connect. Import straight from your **`~/.ssh/config`** (nicknames and all) or auto-discover your **Tailscale** tailnet.
- **Connect by nickname** — uses your SSH config aliases; optional **Tailscale SSH** for keyless, tailnet-authenticated connections, and **Cloudflare Tunnel** for hosts behind Cloudflare Access.
- **Persistent sessions** — connections are backed by tmux on the box, so your work survives closing the app, going idle, or losing the network. Reopen remux and you're **right back where you left off**.
- **Rooms** — shared workspaces on a server (a collapsible panel in the sidebar). See who's in each session live, create and join sessions, all on one machine.
- **Dual-pane file manager** — Local ⟷ Server side by side with native macOS file icons. **Drag files across to transfer** (SFTP), search, hide dotfiles.
- **Session browser** — see the **tmux _and_ tmate** sessions on a server; attach to one or kill any, from the UI.
- **Share with a friend** — pair or watch-only, two ways:
  - **tmate** — a link anyone can open from any terminal, no tailnet.
  - **Cloudflare** — a clickable `remux://` invite backed by an ephemeral, room-scoped key and a quick tunnel. Fully revocable.

Plus everything it inherits from cmux: a fast Ghostty-powered terminal, a built-in scriptable browser, vertical tabs, and a CLI/socket API.

## Build from source

```bash
git clone --recurse-submodules https://github.com/mylesndavid/remux.git
cd remux
./scripts/setup.sh                       # submodules + GhosttyKit (needs zig 0.15.2)
./scripts/reload.sh --tag dev --launch
```

## Credits & license

remux is a fork of [**cmux**](https://github.com/manaflow-ai/cmux) by Manaflow — all credit to its authors for the terminal, browser, and app foundation. Licensed **[GPL-3.0-or-later](LICENSE)**; remux is a derivative work distributed under the same terms.
