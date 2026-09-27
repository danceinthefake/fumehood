defmodule Fumehood.Models.AuditEntry do
  @moduledoc """
  One line of the audit log (DESIGN.md §7). Append-only: the table's triggers
  refuse updates and deletes.

  `action`: `read` · `dry_run` · `commit` · `restore_dry_run` · `restore_commit`,
  or `run` for a statement blocked before it could be classified
  `outcome`: `started` (written *before* a commit or restore touches the
  database) · `ok` · `blocked` · `error` · `cancelled`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w(run read dry_run commit restore_dry_run restore_commit)
  @outcomes ~w(started ok blocked error cancelled)
  @fields ~w(at user source database action sql outcome rule message rows expected_count duration_ms backup_id restore_of)a

  schema "audit_entries" do
    field :at, :utc_datetime_usec
    field :user, :string
    field :source, :string
    field :database, :string
    field :action, :string
    field :sql, :string
    field :outcome, :string
    field :rule, :string
    field :message, :string
    field :rows, :integer
    field :expected_count, :integer
    field :duration_ms, :integer
    field :backup_id, :string
    field :restore_of, :string
  end

  @type t :: %__MODULE__{}

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required([:at, :user, :source, :database, :action, :outcome])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:outcome, @outcomes)
  end
end
