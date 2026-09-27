// Thin client for fumehood's JSON API (see DESIGN.md §8). Every call
// resolves to { ok: true, data } or { ok: false, error: { rule, message } }.

export type ApiError = { rule: string; message: string };
export type Result<T> = { ok: true; data: T } | { ok: false; error: ApiError };

export type Database = { id: string; label: string; mode: "read_only" | "read_write" };
export type Identity = { id: string; source: string };

export type ReadResult = {
  kind: "read";
  command: string;
  columns: string[];
  rows: unknown[][];
  truncated: boolean;
};

export type DryRun = {
  kind: "write";
  command: string;
  table: string;
  count: number;
  // which rows the dry run touched (UPDATE / DELETE); the commit must match
  rows_token: string | null;
  // what else changes with this table and isn't backed up (triggers, cascades)
  warnings: string[];
  columns: string[];
  preview: unknown[][];
};

export type Committed = { count: number; backup_id: string };

export type Backup = {
  id: string;
  operation: string;
  table: string;
  rows: number;
  statement: string;
  user: string | null;
  taken_at: string;
  restore_of: string | null;
};

export type RestorePlan = {
  sql: string;
  count: number;
  rows_token: string | null;
  warnings: string[];
  columns: string[];
  preview: unknown[][];
};

async function call<T>(method: string, path: string, body?: unknown): Promise<Result<T>> {
  try {
    const res = await fetch(`/api${path}`, {
      method,
      // The API only accepts JSON on POST (cross-site request protection).
      headers: method === "GET" ? {} : { "content-type": "application/json" },
      body: method === "GET" ? undefined : JSON.stringify(body ?? {}),
    });
    const json = await res.json();
    return res.ok ? { ok: true, data: json } : { ok: false, error: json.error };
  } catch (e) {
    return { ok: false, error: { rule: "network", message: String(e) } };
  }
}

export const api = {
  me: () => call<Identity>("GET", "/me"),
  databases: () => call<{ databases: Database[] }>("GET", "/databases"),
  // query_id: chosen here so the query can be cancelled while it runs
  run: (db: string, sql: string, query_id: string) =>
    call<ReadResult | DryRun>("POST", `/databases/${db}/run`, { sql, query_id }),
  commit: (db: string, sql: string, dry: DryRun, query_id: string) =>
    call<Committed>("POST", `/databases/${db}/commit`, {
      sql,
      expected_count: dry.count,
      rows_token: dry.rows_token,
      query_id,
    }),
  cancel: (query_id: string) => call<{ cancelled: boolean }>("POST", `/queries/${query_id}/cancel`),
  backups: (db: string) => call<{ backups: Backup[] }>("GET", `/databases/${db}/backups`),
  restore: (db: string, id: string) =>
    call<RestorePlan>("POST", `/databases/${db}/backups/${id}/restore`, {}),
  restoreCommit: (db: string, id: string, plan: RestorePlan) =>
    call<Committed>("POST", `/databases/${db}/backups/${id}/restore/commit`, {
      expected_count: plan.count,
      rows_token: plan.rows_token,
    }),
};
