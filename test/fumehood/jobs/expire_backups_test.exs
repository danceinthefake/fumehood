defmodule Fumehood.Jobs.ExpireBackupsTest do
  use ExUnit.Case, async: true

  alias Fumehood.Jobs.ExpireBackups

  @moduletag :tmp_dir

  defp backup!(dir, id, opts \\ []) do
    File.write!(Path.join(dir, id <> ".json"), "{}")
    unless opts[:json_only], do: File.write!(Path.join(dir, id <> ".csv"), "id\n")
  end

  test "deletes backups taken before the cutoff, csv and json together", %{tmp_dir: dir} do
    backup!(dir, "20260101T000000-aaaaaaaa")
    backup!(dir, "20260801T120000-bbbbbbbb", json_only: true)
    backup!(dir, "20260926T235959-cccccccc")
    File.write!(Path.join(dir, "notes.txt"), "not ours")

    assert ExpireBackups.expire_dir(dir, ~U[2026-09-01 00:00:00Z]) == 2

    assert Enum.sort(File.ls!(dir)) == [
             "20260926T235959-cccccccc.csv",
             "20260926T235959-cccccccc.json",
             "notes.txt"
           ]
  end

  test "age comes from the backup id, not the file's modification time", %{tmp_dir: dir} do
    backup!(dir, "20250101T000000-dddddddd")
    # freshly written files, but taken long ago according to their id
    assert ExpireBackups.expire_dir(dir, ~U[2026-01-01 00:00:00Z]) == 1
    assert File.ls!(dir) == []
  end

  test "a missing directory is nothing to do", %{tmp_dir: dir} do
    assert ExpireBackups.expire_dir(Path.join(dir, "nope"), DateTime.utc_now()) == 0
  end

  test "run_now applies each database's retention", %{tmp_dir: _} do
    # test_helper's config: backups in a temp dir, retention 30 days (default)
    config = Fumehood.Databases.config()
    dir = Path.join(config.backup_dir, "pg16")
    File.mkdir_p!(dir)
    id = "19990101T000000-#{System.unique_integer([:positive])}"
    backup!(dir, id)

    job =
      start_supervised!(
        {ExpireBackups, name: nil, every_hours: 24, now: fn -> ~U[2026-09-27 00:00:00Z] end}
      )

    assert ExpireBackups.run_now(job) >= 1
    refute File.exists?(Path.join(dir, id <> ".csv"))
  end
end
