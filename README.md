# Paperclip AI

An Omarchy bar widget for a local [PaperclipAI](https://github.com/paperclipai/paperclip)
server. A paperclip icon on the bar shows whether the service is running, and
a keyboard-driven panel starts and stops it, tails its logs, opens the web UI,
and shows live health details.

This is an unofficial community plugin. It is not affiliated with the
PaperclipAI project.

<img src="preview.png" alt="The Paperclip AI panel and its colored log view under the Omarchy bar" width="760">

- The bar icon uses your theme's accent color while the service runs and the
  muted color when it is stopped. It follows `omarchy theme set`.
- The panel header has a switch that starts and stops the service. While
  systemd catches up, the panel shows "Starting…" or "Stopping…".
- Health details come from `/api/health`: version, uptime, bootstrap status,
  auth readiness, database backup status and age, and feature flags.
- PaperclipAI stays localhost-only by default. When Tailscale is installed
  and running, a TAILNET section appears that shares the server privately on
  your tailnet with `tailscale serve` and shows its HTTPS URL.
- If PaperclipAI isn't installed yet, the panel shows a SETUP view that
  walks you through it (see [Setup](#setup)).
- An ADAPTER LOGINS section shows whether the Claude Code and Codex CLIs on
  this machine are logged in, using each CLI's own status command.
- Every control is on one keyboard cursor, so the panel works without a mouse.

## Requirements

- Omarchy with the Quickshell-based Omarchy shell.
- PaperclipAI running as a systemd **user** service. The default unit name is
  `paperclipai.service`. See [Configuration](#configuration) to use another one.
  If you don't have it yet, the panel's setup view helps (below).
- `curl`, which Omarchy installs by default.

## Setup

When the configured unit doesn't exist (`systemctl --user cat`) and there is no
`paperclipai` command on your `PATH`, the panel replaces the service switch with
a SETUP view:

1. **Node.js missing or older than 24.11** (PaperclipAI's minimum). The panel
   only shows Omarchy's own installer command and a Copy button:

   ```bash
   omarchy install dev-env node
   ```

   Run it in a terminal yourself, then press R to check again. The plugin never
   installs Node.
2. **Node.js ready.** "Set up PaperclipAI" (U) opens a terminal through
   `omarchy-launch-tui`, shows the command below and asks you to confirm with
   `y` before running PaperclipAI's official quickstart:

   ```bash
   npx paperclipai@2026.1023.0 onboard --yes --install-service
   ```

   That downloads a pinned `paperclipai` release (2026.1023.0) from npm, creates a trusted
   **localhost-only** (loopback) instance and installs `paperclipai.service`
   as a systemd user service. Copy (C) puts the same command on the clipboard
   if you'd rather run it yourself.

While the setup view is open the panel re-checks every 5 seconds, so it
switches to the normal view once the service exists. For private tailnet
access afterwards, use the TAILNET section (shown only when Tailscale is already
installed and running; the plugin never sets Tailscale up).

The plugin does not configure or update an existing PaperclipAI install.

## Install

```bash
omarchy plugin add https://github.com/lutzlstein/omarchy-paperclip --enable
```

The widget goes in the center section of the bar. Move it with
`omarchy bar move io.github.lutzlstein.paperclip --section right`.

## Uninstall

```bash
omarchy plugin remove io.github.lutzlstein.paperclip
```

This removes the plugin folder and its bar entry. PaperclipAI and its service
are not changed.

## Controls

| Action | Mouse | Keyboard (panel open) |
|--------|-------|-----------------------|
| Open or close the panel | Left-click the bar icon | Esc closes |
| Start or stop the service | The header switch | S |
| View colored logs (`journalctl -f`) | Middle-click the bar icon | V |
| Open the web UI | | O |
| Refresh status | | R |
| Start or stop tailnet serve (Tailscale running) | Click the tailnet row | T |
| Copy the tailnet URL (Tailscale running) | Click the copy row | C |
| Move between controls | Hover | Up/Down or j/k |
| Activate the selected control | Click | Enter or Space |

Open the panel from a keybinding or script with:

```bash
omarchy-shell io.github.lutzlstein.paperclip toggle
```

The IPC target also has `open`, `close`, `toggleService`, `status`,
`toggleTailnet` and `tailnetStatus`.

## Configuration

Set options on the widget's entry in `~/.config/omarchy/shell.json`. The shell
reloads the file on save.

```json
{
  "id": "io.github.lutzlstein.paperclip",
  "apiUrl": "http://localhost:3100",
  "serviceUnit": "paperclipai.service"
}
```

| Key | Default | Purpose |
|-----|---------|---------|
| `apiUrl` | `http://localhost:3100` | Base URL of the PaperclipAI server. The panel reads `<apiUrl>/api/health` and opens `<apiUrl>` in the browser. |
| `serviceUnit` | `paperclipai.service` | systemd user unit to watch, start, stop and tail. |
| `tailnetHttpsPort` | `443` | HTTPS port on your tailnet hostname. Must be an integer from 1 to 65535. The local port comes from `apiUrl` (3100 if it has none). |

### Tailnet mode

The TAILNET section is shown only when `tailscale` is installed and logged in
and running. Otherwise it is hidden and nothing changes. The plugin does not
install or configure Tailscale. The toggle needs your user to be allowed to
change serve config; if it isn't, Tailscale's error is shown. When the HTTPS port
already serves something else, the panel shows "port used elsewhere" and never
overwrites it. If PaperclipAI is in authenticated mode, set its
`publicBaseUrl` to the tailnet URL.

## How it works

- On panel open (and every 5 seconds while the setup view shows) a fixed
  `bash -c` probe with a 10-second timeout checks `systemctl --user cat
  <serviceUnit>`, `command -v paperclipai`, `node --version` (including mise
  shims) and `command -v npx`. Output is capped at 1 KB.
- When the panel opens (at most once a minute, or on R) it runs
  `claude auth status --json` (only `loggedIn` is read) and
  `codex login status` (exit status only), each with an 8-second timeout.
  A row is hidden when that CLI isn't installed. The plugin never reads token
  files or contacts provider APIs. Grok is not shown: the `grok` CLI has no
  non-interactive login-status command.
- The panel does not show whether your browser is signed in to the web UI.
  In authenticated mode `/api/auth/get-session` returns 401 to any request
  without your browser's cookie, so the plugin can't tell. It shows the
  deployment mode and exposure from `/api/health` instead.

- Every 5 seconds the widget runs `systemctl --user is-active <serviceUnit>`.
- Start and stop run `systemctl --user start|stop <serviceUnit>`.
- While the panel is open and the service runs, it requests
  `<apiUrl>/api/health` with `curl` every 10 seconds.
- Logs open in a terminal through `omarchy-launch-tui`, following
  `journalctl --user -f -o cat -u <serviceUnit>`. When `bat` is installed (Omarchy
  ships it), lines pass through `bat -l log --theme=ansi`, so log levels,
  timestamps, routes, status codes and JSON are colored with your terminal's
  theme palette. Without `bat` the plain journal is shown.
- While the panel is open it reads
  `tailscale status --json --peers=false` and `tailscale serve status --json`
  every 5 seconds (5-second timeout each, output capped at 64 KB). If
  `tailscale` is missing or not running, it stops after the first read. Serving is
  "on" when `/` on the HTTPS port proxies to `127.0.0.1:<port>` or
  `localhost:<port>`.
- The tailnet toggle runs `tailscale serve --bg --https=<tailnetHttpsPort>
  http://127.0.0.1:<port>` to turn on and `tailscale serve
  --https=<tailnetHttpsPort> off` to turn off. Copy runs `wl-copy`.

Set up opens a visible terminal and, only after you type `y`, runs
`npx paperclipai@2026.1023.0 onboard --yes --install-service`, which downloads code
from npm, writes PaperclipAI's config and data under `~/.paperclip` and installs
and starts a systemd user service.

The plugin has no other side effects. Everything runs as your own user, and
it does not write files. The tailnet toggle changes Tailscale's serve config,
and only for the configured HTTPS port; other serve ports are left alone. Turning
it on makes the server reachable by devices on your tailnet (not the public
internet; this is not `tailscale funnel`).

## License

MIT. See [LICENSE](LICENSE).
