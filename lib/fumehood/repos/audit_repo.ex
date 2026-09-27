defmodule Fumehood.Repos.AuditRepo do
  @moduledoc "Audit log queries. Insert and read only — there is nothing else."
  import Ecto.Query

  alias Fumehood.Models.AuditEntry
  alias Fumehood.Repo

  @spec insert(map()) :: {:ok, AuditEntry.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs), do: attrs |> AuditEntry.changeset() |> Repo.insert()

  @doc "Entries of a database, newest first; `before` (an id) pages back."
  @spec list(String.t(), pos_integer(), integer() | nil) :: [AuditEntry.t()]
  def list(database, limit, before \\ nil) do
    AuditEntry
    |> where(database: ^database)
    |> then(fn q -> if before, do: where(q, [e], e.id < ^before), else: q end)
    |> order_by(desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end
end
