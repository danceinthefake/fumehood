defmodule Fumehood.Runner do
  @moduledoc """
  Runs statements that passed `Fumehood.Safety` against a target Postgres
  connection (a `Postgrex` connection).

  Every call runs in its own transaction and ends it before returning —
  nothing is left open. See DESIGN.md §5.3.

  Options (all calls):

    * `:statement_timeout` — ms, default 30_000
    * `:lock_timeout` — ms, default 5_000
    * `:max_rows` — rows returned by a read / changed by a write, default 1000
    * `:preview` — rows shown from a write dry run, default 20
  """

  alias Fumehood.Safety.Statement

  @defaults [statement_timeout: 30_000, lock_timeout: 5_000, max_rows: 1000, preview: 20]

  @type result :: %{columns: [String.t()], rows: [list()]}
  @type error :: {:blocked, atom(), String.t()} | {:db_error, String.t()}

  @doc """
  Runs a read inside a `READ ONLY` transaction. SELECTs are capped at
  `:max_rows`; `truncated` tells whether more rows existed.
  """
  @spec read(DBConnection.conn(), Statement.t(), keyword()) ::
          {:ok, %{columns: [String.t()], rows: [list()], truncated: boolean()}}
          | {:error, error()}
  def read(conn, %Statement{kind: :read} = statement, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    max = opts[:max_rows]

    in_transaction(conn, opts, :read_only, fn tx ->
      with {:ok, result} <- query(tx, read_sql(statement, max + 1)) do
        {:ok,
         %{
           columns: result.columns || [],
           rows: Enum.take(result.rows || [], max),
           truncated: length(result.rows || []) > max
         }}
      end
    end)
  end

  @doc """
  Runs a write, counts and previews the rows it changes, then rolls back.
  Nothing is kept.
  """
  @spec dry_run(DBConnection.conn(), Statement.t(), keyword()) ::
          {:ok, %{count: non_neg_integer(), columns: [String.t()], preview: [list()]}}
          | {:error, error()}
  def dry_run(conn, %Statement{kind: :write} = statement, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)

    in_transaction(conn, opts, :rollback, fn tx ->
      with :ok <- require_primary_key(tx, statement),
           {:ok, result} <- query(tx, statement.sql <> "\nRETURNING *"),
           :ok <- within_limit(result.num_rows, opts[:max_rows]) do
        {:ok,
         %{
           count: result.num_rows,
           columns: result.columns,
           preview: Enum.take(result.rows, opts[:preview])
         }}
      end
    end)
  end

  @doc """
  Primary key columns of a table as `[{name, type}]` in key order, `[]` when
  the table has none, or `nil` when the table doesn't exist.
  """
  @spec primary_key(DBConnection.conn(), {String.t() | nil, String.t()}) ::
          [{String.t(), String.t()}] | nil
  def primary_key(conn, {schema, name}) do
    sql = """
    SELECT a.attname, format_type(a.atttypid, a.atttypmod), r.oid IS NULL
    FROM (SELECT to_regclass(CASE WHEN $1::text IS NULL THEN format('%I', $2::text)
                                  ELSE format('%I.%I', $1::text, $2::text) END) AS oid) r
    LEFT JOIN pg_index i ON i.indrelid = r.oid AND i.indisprimary
    LEFT JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = ANY (i.indkey)
    ORDER BY array_position(i.indkey::int2[], a.attnum)
    """

    case Postgrex.query!(conn, sql, [schema, name]).rows do
      [[nil, nil, true]] -> nil
      [[nil, nil, false]] -> []
      rows -> Enum.map(rows, fn [column, type, _] -> {column, type} end)
    end
  end

  # -- internals -------------------------------------------------------------

  # SELECTs are wrapped to cap the rows; EXPLAIN / SHOW run as they are.
  # New lines around the statement keep a trailing `-- comment` from
  # swallowing what we add.
  defp read_sql(%Statement{command: :select, sql: sql}, limit),
    do: "SELECT * FROM (\n#{sql}\n) AS fumehood_read LIMIT #{limit}"

  defp read_sql(%Statement{sql: sql}, _limit), do: sql

  defp require_primary_key(_tx, %Statement{command: :insert}), do: :ok

  defp require_primary_key(tx, %Statement{table: table}) do
    case primary_key(tx, table) do
      nil ->
        {:error, {:db_error, "Table #{format_table(table)} doesn't exist."}}

      [] ->
        blocked(
          :no_primary_key,
          "#{format_table(table)} has no primary key; its rows can't be backed up and restored reliably."
        )

      _columns ->
        :ok
    end
  end

  defp within_limit(count, max) when count <= max, do: :ok

  defp within_limit(count, max),
    do:
      blocked(
        :too_many_rows,
        "This would change #{count} rows; the limit is #{max}. Split it into smaller changes."
      )

  # Opens a transaction, applies the guardrails, runs `fun`, and ends it:
  # `:read_only` and `:commit` commit when `fun` succeeds, `:rollback` always
  # rolls back. Any error rolls back.
  defp in_transaction(conn, opts, mode, fun) do
    Postgrex.transaction(conn, fn tx ->
      if mode == :read_only, do: Postgrex.query!(tx, "SET TRANSACTION READ ONLY", [])
      Postgrex.query!(tx, "SET LOCAL statement_timeout = #{opts[:statement_timeout]}", [])
      Postgrex.query!(tx, "SET LOCAL lock_timeout = #{opts[:lock_timeout]}", [])

      case fun.(tx) do
        {:ok, value} when mode == :rollback -> Postgrex.rollback(tx, {:ok, value})
        {:ok, value} -> value
        {:error, reason} -> Postgrex.rollback(tx, {:error, reason})
      end
    end)
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, {:error, reason}} -> {:error, reason}
    end
  end

  defp query(tx, sql) do
    case Postgrex.query(tx, sql, []) do
      {:ok, result} -> {:ok, result}
      {:error, %Postgrex.Error{postgres: %{message: message}}} -> {:error, {:db_error, message}}
      {:error, error} -> {:error, {:db_error, Exception.message(error)}}
    end
  end

  defp blocked(rule, message), do: {:error, {:blocked, rule, message}}

  defp format_table({nil, name}), do: name
  defp format_table({schema, name}), do: "#{schema}.#{name}"
end
