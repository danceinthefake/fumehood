defmodule Fumehood.ValuesTest do
  use ExUnit.Case, async: true

  alias Fumehood.Values

  setup do
    Fumehood.TargetDB.connect!(16)
  end

  test "values read like Postgres output, by column type", %{conn: conn} do
    sql = """
    SELECT '0f7b1a2c-3d4e-4f50-8a9b-0c1d2e3f4a5b'::uuid, '\\x01ff'::bytea, 'plain text'::text,
           1.50::numeric, '2026-09-27 10:00:00+00'::timestamptz, '2026-09-27'::date,
           '{1,2}'::int[], '{"x": 1}'::jsonb, '1 year 2 mons 3 days 04:05:06.5'::interval,
           '-00:00:01'::interval, '10.0.0.0/8'::cidr, 'NaN'::float8, true, NULL::int,
           '{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}'::uuid[], '{"\\\\x01"}'::bytea[]
    """

    {:ok, query, result} = Postgrex.prepare_execute(conn, "", sql, [])
    [row] = Values.rows(result.rows, Enum.zip(query.result_types, query.result_oids))

    assert row == [
             "0f7b1a2c-3d4e-4f50-8a9b-0c1d2e3f4a5b",
             "\\x01ff",
             "plain text",
             "1.50",
             "2026-09-27T10:00:00.000000Z",
             "2026-09-27",
             [1, 2],
             %{"x" => 1},
             "1 year 2 mons 3 days 04:05:06.5",
             "-00:00:01",
             "10.0.0.0/8",
             "NaN",
             true,
             nil,
             ["a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"],
             ["\\x01"]
           ]

    assert JSON.encode!(row)
  end
end
