defmodule Fumehood.Values do
  @moduledoc """
  Turns values from Postgrex into JSON-safe values that read like Postgres
  output, using the column's type (Postgrex returns a `uuid` as 16 raw bytes,
  `bytea` as raw binary, `numeric` as `Decimal`, …).
  """

  @bytea 17
  @uuid 2950

  @doc """
  Converts one value. `type` is `{postgrex_type, oid}` — the column's entries
  in the prepared query's `result_types` and `result_oids`. The OID matters:
  Postgrex decodes `text` and `bytea` with the same extension.
  """
  @spec display(term(), {tuple(), non_neg_integer() | nil} | nil) :: term()
  def display(nil, _type), do: nil
  def display(value, {_, @uuid}), do: uuid(value)
  def display(value, {_, @bytea}) when is_binary(value), do: bytes(value)

  # Array element OIDs come with the array's type: {Array, [elem_oid], [elem_type], _}
  def display(values, {{Postgrex.Extensions.Array, [oid | _], [inner | _], _}, _})
      when is_list(values),
      do: Enum.map(values, &display(&1, {inner, oid}))

  def display(values, _type) when is_list(values), do: Enum.map(values, &display(&1, nil))
  def display(%Decimal{} = value, _type), do: Decimal.to_string(value, :normal)

  def display(%struct{} = value, _type) when struct in [Date, Time, NaiveDateTime, DateTime],
    do: struct.to_iso8601(value)

  def display(%Postgrex.INET{address: address, netmask: mask}, _type) do
    ip = address |> :inet.ntoa() |> to_string()
    if mask, do: "#{ip}/#{mask}", else: ip
  end

  def display(%Postgrex.Interval{} = value, _type), do: interval(value)
  def display(%_{} = value, _type), do: inspect(value)

  def display(value, _type) when is_atom(value) and not is_boolean(value),
    do: Atom.to_string(value)

  def display(value, _type) when is_binary(value),
    do: if(String.valid?(value), do: value, else: bytes(value))

  def display(value, _type), do: value

  @doc "Converts rows using the query's result types."
  @spec rows([list()], [tuple()]) :: [list()]
  def rows(rows, types), do: Enum.map(rows, fn row -> Enum.zip_with(row, types, &display/2) end)

  defp uuid(<<a::32, b::16, c::16, d::16, e::48>>) do
    [pad(a, 8), pad(b, 4), pad(c, 4), pad(d, 4), pad(e, 12)] |> Enum.join("-")
  end

  defp uuid(value), do: display(value, nil)

  defp pad(n, width),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  # Postgres style: "1 year 2 mons 3 days 04:05:06.5"
  defp interval(%{months: months, days: days, secs: secs, microsecs: micro}) do
    years = div(months, 12)
    months = rem(months, 12)
    total = secs * 1_000_000 + micro
    sign = if total < 0, do: "-", else: ""
    total = abs(total)
    {h, rest} = {div(total, 3_600_000_000), rem(total, 3_600_000_000)}
    {m, rest} = {div(rest, 60_000_000), rem(rest, 60_000_000)}
    {s, us} = {div(rest, 1_000_000), rem(rest, 1_000_000)}

    fraction =
      if us == 0,
        do: "",
        else: "." <> String.trim_trailing(String.pad_leading("#{us}", 6, "0"), "0")

    clock =
      if total == 0 and (years != 0 or months != 0 or days != 0),
        do: nil,
        else: "#{sign}#{two(h)}:#{two(m)}:#{two(s)}#{fraction}"

    [unit(years, "year", "years"), unit(months, "mon", "mons"), unit(days, "day", "days"), clock]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp unit(0, _one, _many), do: nil
  defp unit(n, one, many), do: "#{n} #{if abs(n) == 1, do: one, else: many}"
  defp two(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp bytes(value), do: "\\x" <> Base.encode16(value, case: :lower)
end
