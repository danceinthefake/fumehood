# fumehood

Run queries against production PostgreSQL safely: dangerous statements are
blocked, every query runs inside a transaction, every `UPDATE` / `DELETE` is
backed up before it commits, and every action is audited.

Design: [DESIGN.md](DESIGN.md).

## Development

Runtimes are pinned in `mise.toml` (Erlang 29.1.1, Elixir 1.20.4).

```sh
mise install          # Erlang + Elixir
mise exec -- mix setup
mise exec -- mix test
mise exec -- mix phx.server   # http://localhost:4000
```
