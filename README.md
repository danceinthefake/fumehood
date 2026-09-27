# fumehood

Run queries against production PostgreSQL safely: dangerous statements are
blocked, every query runs inside a transaction, every `UPDATE` / `DELETE` is
backed up before it commits, and every action is audited.

Design: [DESIGN.md](DESIGN.md).

## Development

Runtimes are pinned in `mise.toml` (Erlang 29.1.1, Elixir 1.20.4).

```sh
mise install          # Erlang + Elixir
docker compose up -d  # target Postgres 16 + 18 for integration tests
mise exec -- mix setup
mise exec -- mix test
(cd assets && mise exec -- pnpm install && mise exec -- pnpm build)
mise exec -- mix phx.server   # http://localhost:4000
```

The UI (`assets/`, Vue + [blessing-ui](../blessing-ui)) is built into
`priv/static` and served by Phoenix. While working on it, run
`mise exec -- pnpm dev` in `assets/` (Vite on :5173, `/api` forwarded to
:4000). `FUMEHOOD_DEV_USER=you@example.com` sets who you are in development.

blessing-ui is not on npm yet: `assets/package.json` takes it from
`../../blessing-ui` (a checkout next to this repo, with `dist/` built).
