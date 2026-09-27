defmodule Fumehood.Jobs.ExpireBackups do
  @moduledoc """
  Deletes backups older than each database's `backup_retention_days`
  (default 30; DESIGN.md §5.4) — backup files hold production data, so they
  must not pile up. Runs every `:every_hours` (default 6) inside fumehood; no
  cron.

  A backup's age comes from its id (`20260927T120000-ab12cd34`, the UTC time
  it was taken), not the file's modification time, which copying or touching
  a file would change. Its `.csv` and `.json` go together.
  """
  use GenServer
  require Logger

  alias Fumehood.Databases

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Runs one pass now; returns how many backups were deleted."
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now)

  @impl true
  def init(opts) do
    state = %{
      every: Keyword.get(opts, :every_hours, 6),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    expire(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:run_now, _from, state), do: {:reply, expire(state), state}

  defp schedule(state), do: Process.send_after(self(), :tick, state.every * 3_600_000)

  defp expire(state) do
    config = Databases.config()
    now = state.now.()

    config.databases
    |> Map.values()
    |> Enum.map(fn db ->
      dir = Path.join(config.backup_dir, db.id)
      cutoff = DateTime.add(now, -db.backup_retention_days, :day)
      count = expire_dir(dir, cutoff)

      if count > 0,
        do:
          Logger.info(
            "deleted #{count} backup(s) of #{db.id} older than #{db.backup_retention_days} days"
          )

      count
    end)
    |> Enum.sum()
  end

  @doc false
  # Deletes backups in `dir` taken before `cutoff`; returns how many.
  def expire_dir(dir, cutoff) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.map(&Path.rootname/1)
        |> Enum.uniq()
        |> Enum.filter(&older?(&1, cutoff))
        |> Enum.map(fn id ->
          for ext <- [".csv", ".json"], do: File.rm(Path.join(dir, id <> ext))
          id
        end)
        |> length()

      {:error, _} ->
        0
    end
  end

  # Ids we didn't write (no timestamp prefix) are left alone.
  defp older?(id, cutoff) do
    with <<stamp::binary-size(15), "-", _::binary>> <- id,
         {:ok, taken} <- parse(stamp) do
      DateTime.before?(taken, cutoff)
    else
      _ -> false
    end
  end

  defp parse(
         <<y::binary-4, m::binary-2, d::binary-2, "T", hh::binary-2, mm::binary-2, ss::binary-2>>
       ),
       do:
         with(
           {:ok, dt, 0} <- DateTime.from_iso8601("#{y}-#{m}-#{d}T#{hh}:#{mm}:#{ss}Z"),
           do: {:ok, dt}
         )

  defp parse(_), do: :error
end
