# noctalia-clockmost

A [Noctalia](https://github.com/noctalia-dev/noctalia-shell) plugin source with
one plugin: **`benylin/clockmost`** — a bar widget showing the status of the
`clockmost` home server (pending updates, alerts, deploy state, container health)
via a single `ssh <host> clockmost-status` call.

See [`clockmost/README.md`](clockmost/README.md).

## Install

```sh
noctalia msg plugins source add clockmost git https://git.clockmost.com/Benylin/noctalia-clockmost.git
noctalia msg plugins update clockmost
noctalia msg plugins enable benylin/clockmost
```
