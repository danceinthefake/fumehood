# fumehood

Run queries against production PostgreSQL safely: dangerous statements are
blocked, every query runs inside a transaction, every `UPDATE` / `DELETE` is
backed up before it commits, and every action is audited.

- Reads run in a read-only transaction with a row limit and a timeout.
- Writes go through a dry run first: you see how many rows change and what
  they look like, then confirm.
- Before a write commits, the rows it changes are saved to CSV; the Backups
  tab restores them, with the same dry run → confirm.
- DDL, `TRUNCATE`, writes without `WHERE`, and more are blocked by parsing
  the SQL with Postgres's own parser.
- Who did what is in an append-only audit log, live in the UI.
- No user accounts: people sign in through Google Cloud IAP or an SSH
  tunnel, and IAM decides who gets in.

Built with Elixir, Phoenix and Vue ([blessing-ui](https://www.npmjs.com/package/blessing-ui)).

- Install: [docs/install.md](docs/install.md)
- Postgres roles, secrets, two-instance setup: [docs/setup.md](docs/setup.md)
- Design: [DESIGN.md](DESIGN.md)
- Changes: [CHANGELOG.md](CHANGELOG.md)

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


## License

MIT — see [LICENSE](LICENSE).
