defmodule Fumehood.Repo.Migrations.CreateAuditEntries do
  use Ecto.Migration

  def change do
    create table(:audit_entries) do
      add :at, :utc_datetime_usec, null: false
      add :user, :text, null: false
      add :source, :text, null: false
      add :database, :text, null: false
      add :action, :text, null: false
      add :sql, :text
      add :outcome, :text, null: false
      add :rule, :text
      add :message, :text
      add :rows, :integer
      add :expected_count, :integer
      add :duration_ms, :integer
      add :backup_id, :text
      add :restore_of, :text
    end

    create index(:audit_entries, [:database, :id])

    # Append-only, enforced by the database: no row can be changed or removed
    # through any code path.
    execute(
      """
      CREATE TRIGGER audit_entries_no_update BEFORE UPDATE ON audit_entries
      BEGIN SELECT RAISE(ABORT, 'audit log is append-only'); END
      """,
      "DROP TRIGGER audit_entries_no_update"
    )

    execute(
      """
      CREATE TRIGGER audit_entries_no_delete BEFORE DELETE ON audit_entries
      BEGIN SELECT RAISE(ABORT, 'audit log is append-only'); END
      """,
      "DROP TRIGGER audit_entries_no_delete"
    )
  end
end
