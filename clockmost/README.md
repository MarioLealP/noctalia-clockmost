# clockmost — Noctalia bar widget

Home-server status at a glance on the Noctalia bar.

| glyph | meaning |
|---|---|
| `server` (accent) | all clear |
| `alert-triangle` (amber) | pending updates, a failed unit, a low-severity alert, or disk >85% |
| `alert-octagon` (red) | a container down/unhealthy, a High+ alert, or the deploy loop rolled back |

The glyph text shows `updates + alerts` count. Hover for the full breakdown:
pending Renovate PRs, Zabbix problems, container health, failed units, last
deploy, disk.

- **left-click** — drop the breakdown into a notification
- **right-click** — open Arcane
- **middle-click** — open the infra repo's pull requests

## How it works

One call per refresh: `ssh <ssh_host> clockmost-status`. That server-side script
(`/usr/local/sbin/clockmost-status`) emits a JSON snapshot and holds all the
tokens (Gitea read token, Zabbix API token). The desktop only needs its existing
passwordless SSH to the server (default host alias `clockmost-claude`).

## Requires

- SSH access to the server as a user that can run `clockmost-status`
- `xdg-open` (for the click actions)

## Live toasts

The `notify-svc` service polls `ssh <ssh_host> clockmost-notifications` every
`toast_poll_seconds` (default 25) and raises a desktop notification for each new
message on the ntfy `clockmost` topic. `toast_min_priority` filters by ntfy
priority (1 = everything, 4 = high+ only). `toasts_enabled = false` turns it off.
The ntfy token stays on the server — the desktop only uses SSH.
