defmodule Fumehood.Backup do
  @moduledoc """
  Backup files written before a write commits (DESIGN.md §5.4):

    * `<id>.csv` — the rows exactly as they were, written by Postgres `COPY`
      (only for `UPDATE` / `DELETE`);
    * `<id>.json` — what was changed and how to find the rows again.

  Files are written with `:sync` so they are on disk before the change
  commits.
  """

  @type meta :: %{
          required(:id) => String.t(),
          required(:operation) => :insert | :update | :delete,
          required(:table) => String.t(),
          required(:primary_key) => [String.t()],
          required(:keys) => [[String.t()]],
          required(:statement) => String.t(),
          optional(atom()) => term()
        }

  @doc "A new backup id: sortable by time, unique."
  @spec new_id() :: String.t()
  def new_id do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    "#{stamp}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
  end

  @doc """
  Writes the backup files into `dir` and returns their paths. `csv` is `nil`
  for `INSERT`, which only needs the keys to be undone.
  """
  @spec write(Path.t(), meta(), iodata() | nil) ::
          {:ok, %{csv: Path.t() | nil, json: Path.t()}} | {:error, String.t()}
  def write(dir, %{id: id} = meta, csv) do
    csv_path = csv && Path.join(dir, "#{id}.csv")
    json_path = Path.join(dir, "#{id}.json")
    meta = Map.put(meta, :taken_at, DateTime.utc_now() |> DateTime.to_iso8601())

    with :ok <- File.mkdir_p(dir),
         :ok <- write_synced(csv_path, csv),
         :ok <- write_synced(json_path, JSON.encode!(meta)) do
      {:ok, %{csv: csv_path, json: json_path}}
    else
      {:error, reason} -> {:error, "Backup couldn't be written to #{dir}: #{inspect(reason)}"}
    end
  end

  # ponytail: file is synced, its directory entry isn't (no fsync of the dir);
  # add a dir fsync if backups must survive power loss right after commit.
  defp write_synced(nil, _data), do: :ok
  defp write_synced(path, data), do: :file.write_file(path, data, [:sync])
end
