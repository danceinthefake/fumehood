defmodule Fumehood.Safety do
  @moduledoc """
  Decides whether a SQL text may run, and on which path.

  The text is parsed with Postgres's own parser (`pg_query_ex`), and the rules
  run on the parse tree — comments, casing or quoting can't hide a statement.
  Anything not explicitly allowed is blocked.

  Pure: no database access. See DESIGN.md §5.2 for the rule table.
  """

  defmodule Statement do
    @moduledoc "A statement that passed the rules."

    @enforce_keys [:kind, :command]
    defstruct [:kind, :command, :table, :ast]

    @type t :: %__MODULE__{
            kind: :read | :write,
            command: :select | :explain | :show | :insert | :update | :delete,
            table: {schema :: String.t() | nil, name :: String.t()} | nil,
            ast: term()
          }
  end

  @type rule ::
          :parse_error
          | :empty
          | :multiple_statements
          | :missing_where
          | :writing_cte
          | :denied_function
          | :select_into
          | :row_locking
          | :explain_analyze_write
          | :merge
          | :transaction_control
          | :maintenance
          | :ddl
          | :not_allowed

  @type blocked :: {:blocked, rule(), message :: String.t()}

  # Functions with side effects outside the statement itself, or that run
  # arbitrary SQL given as a string. Matched on the unqualified name.
  @denied_functions ~w(
    pg_terminate_backend pg_cancel_backend pg_reload_conf pg_rotate_logfile
    pg_promote pg_switch_wal pg_create_restore_point pg_notify
    pg_logical_emit_message set_config
    pg_read_file pg_read_binary_file pg_ls_dir pg_stat_file
    query_to_xml query_to_xml_and_xmlschema query_to_xmlschema cursor_to_xml
  )
  @denied_prefixes ~w(dblink lo_ pg_advisory pg_try_advisory)

  @dml [:insert_stmt, :update_stmt, :delete_stmt, :merge_stmt]
  @maintenance [:copy_stmt, :vacuum_stmt, :cluster_stmt, :reindex_stmt, :lock_stmt]
  @transaction_control [:transaction_stmt, :variable_set_stmt]
  @ddl_prefixes ~w(create alter drop truncate grant rename index view comment reassign)

  @doc """
  Checks one SQL text. Returns the classified statement, or why it is blocked.
  """
  @spec check(String.t()) :: {:ok, Statement.t()} | {:error, blocked()}
  def check(sql) when is_binary(sql) do
    with {:ok, node} <- parse_single(sql),
         :ok <- no_denied_functions(node) do
      classify(node)
    end
  end

  # -- parsing ---------------------------------------------------------------

  defp parse_single(sql) do
    case PgQuery.parse(sql) do
      {:ok, %{stmts: [%{stmt: %{node: node}}]}} ->
        {:ok, node}

      {:ok, %{stmts: []}} ->
        blocked(:empty, "Nothing to run.")

      {:ok, %{stmts: _}} ->
        blocked(:multiple_statements, "Run one statement at a time.")

      {:error, %{message: message}} ->
        blocked(:parse_error, "Postgres can't parse this: #{message}")
    end
  end

  # -- classification --------------------------------------------------------

  defp classify({:select_stmt, s} = node) do
    cond do
      s.into_clause != nil ->
        blocked(:select_into, "SELECT … INTO creates a table and is not allowed.")

      s.locking_clause != [] ->
        blocked(:row_locking, "Row locking (FOR UPDATE / FOR SHARE) is not allowed.")

      writes_inside?(s) ->
        writing_cte()

      true ->
        read(:select, node)
    end
  end

  defp classify({:explain_stmt, e} = node) do
    if analyze?(e) do
      # EXPLAIN ANALYZE executes the statement: only allowed when that
      # statement would itself be allowed as a read.
      case classify(e.query.node) do
        {:ok, %Statement{kind: :read}} ->
          read(:explain, node)

        {:ok, %Statement{kind: :write}} ->
          blocked(
            :explain_analyze_write,
            "EXPLAIN ANALYZE runs the statement; not allowed for writes. Use EXPLAIN without ANALYZE."
          )

        error ->
          error
      end
    else
      read(:explain, node)
    end
  end

  defp classify({:variable_show_stmt, _} = node), do: read(:show, node)

  defp classify({:insert_stmt, s} = node) do
    if writes_inside?(s), do: writing_cte(), else: write(:insert, s.relation, node)
  end

  defp classify({type, s} = node) when type in [:update_stmt, :delete_stmt] do
    command = if type == :update_stmt, do: :update, else: :delete

    cond do
      s.where_clause == nil ->
        blocked(:missing_where, "#{String.upcase("#{command}")} without WHERE is not allowed.")

      writes_inside?(s) ->
        writing_cte()

      true ->
        write(command, s.relation, node)
    end
  end

  defp classify({:merge_stmt, _}) do
    blocked(:merge, "MERGE is not supported: its changed rows can't be backed up before commit.")
  end

  defp classify({type, _}) when type in @transaction_control do
    blocked(
      :transaction_control,
      "fumehood manages the transaction; BEGIN / COMMIT / SET are not allowed."
    )
  end

  defp classify({type, _}) when type in @maintenance do
    blocked(:maintenance, "#{statement_name(type)} is not allowed.")
  end

  defp classify({type, _}) do
    name = statement_name(type)

    if String.starts_with?(Atom.to_string(type), @ddl_prefixes) do
      blocked(:ddl, "Schema and permission changes (#{name}) are not allowed.")
    else
      blocked(:not_allowed, "#{name} is not allowed.")
    end
  end

  # -- rule helpers ----------------------------------------------------------

  defp no_denied_functions(node) do
    case Enum.find(function_names(node), &denied_function?/1) do
      nil -> :ok
      name -> blocked(:denied_function, "Function #{name}() is not allowed.")
    end
  end

  defp denied_function?(name) do
    name in @denied_functions or String.starts_with?(name, @denied_prefixes)
  end

  defp function_names(node) do
    walk(node, [], fn
      {:func_call, %{funcname: parts}}, acc -> [unqualified(parts) | acc]
      _, acc -> acc
    end)
  end

  defp unqualified(parts) do
    parts
    |> List.last()
    |> then(fn %{node: {:string, %{sval: name}}} -> String.downcase(name) end)
  end

  # A data-modifying statement nested anywhere below the top statement
  # (only possible through WITH … AS (INSERT/UPDATE/DELETE …)).
  defp writes_inside?(struct) do
    walk(struct, false, fn
      {type, _}, _acc when type in @dml -> true
      _, acc -> acc
    end)
  end

  defp analyze?(%{options: options}) do
    Enum.any?(options, fn %{node: {:def_elem, %{defname: name}}} -> name == "analyze" end)
  end

  defp writing_cte do
    blocked(
      :writing_cte,
      "Data-changing WITH clauses (WITH … AS (INSERT/UPDATE/DELETE …)) are not allowed."
    )
  end

  # Visits every {tag, value} node of the parse tree, depth first.
  defp walk({tag, value} = node, acc, fun) when is_atom(tag) do
    walk(value, fun.(node, acc), fun)
  end

  defp walk(%_{} = struct, acc, fun),
    do: struct |> Map.from_struct() |> Map.values() |> walk(acc, fun)

  defp walk(list, acc, fun) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, &2, fun))
  defp walk(_leaf, acc, _fun), do: acc

  # -- results ---------------------------------------------------------------

  defp read(command, node), do: {:ok, %Statement{kind: :read, command: command, ast: node}}

  defp write(command, relation, node) do
    {:ok, %Statement{kind: :write, command: command, table: table(relation), ast: node}}
  end

  defp table(%{schemaname: "", relname: name}), do: {nil, name}
  defp table(%{schemaname: schema, relname: name}), do: {schema, name}

  defp blocked(rule, message), do: {:error, {:blocked, rule, message}}

  defp statement_name(type) do
    type
    |> Atom.to_string()
    |> String.replace_suffix("_stmt", "")
    |> String.replace("_", " ")
    |> String.upcase()
  end
end
