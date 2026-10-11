defmodule Kanban.TelemetrySourceScan do
  @moduledoc """
  Finds every telemetry emit site in the app's source, for tests that check the
  source against `Kanban.Telemetry.Catalog`.

  It parses each `.ex` file under `lib/` and walks the syntax tree, so it sees
  calls the way the compiler does, not as text. It records:

    * `Kanban.Telemetry.emit/3,4` and `Kanban.Telemetry.span/3,4` calls, with
      their event name;
    * `emit_telemetry(conn, action, metadata)` calls, which emit
      `[:kanban, :api, action]`;
    * `AuditLog.event(action, metadata)` calls, which emit
      `[:kanban, :audit, action]`;
    * direct `:telemetry.execute` and `:telemetry.span` calls.

  A name is a literal list of atoms, or a module attribute holding one in the
  same file. Anything else is reported as `:dynamic`. Metadata keys are read
  when the metadata argument is a literal map or keyword list, and are
  `:unknown` otherwise.
  """

  @typedoc "One emit site."
  @type site :: %{
          file: String.t(),
          line: non_neg_integer() | nil,
          kind: :emit | :span | :api | :audit,
          name: [atom()] | :dynamic,
          keys: [atom()] | :unknown
        }

  @def_kinds [:def, :defp, :defmacro, :defmacrop, :defdelegate]
  @type_attributes [:spec, :callback, :macrocallback, :type, :typep, :opaque]

  @doc """
  Scans every `.ex` file under `root` (default `lib`) and returns
  `%{sites: [site], raw_calls: [{file, line, :execute | :span}]}`.
  """
  @spec scan(Path.t()) :: %{sites: [site()], raw_calls: [tuple()]}
  def scan(root \\ "lib") do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&scan_file/1)
    |> Enum.reduce(%{sites: [], raw_calls: []}, fn file, acc ->
      %{sites: acc.sites ++ file.sites, raw_calls: acc.raw_calls ++ file.raw_calls}
    end)
  end

  @doc """
  Scans one file. See `scan/1`.
  """
  @spec scan_file(Path.t()) :: %{sites: [site()], raw_calls: [tuple()]}
  def scan_file(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!(columns: false)
    attrs = literal_attributes(ast)
    initial = %{sites: [], raw_calls: []}

    {_ast, found} = Macro.prewalk(ast, initial, &visit(&1, &2, file, attrs))

    %{sites: Enum.reverse(found.sites), raw_calls: Enum.reverse(found.raw_calls)}
  end

  # A function head looks like a call, so it is replaced before the walk
  # reaches it; the body is still walked.
  defp visit({kind, meta, [_head | rest]}, acc, _file, _attrs) when kind in @def_kinds,
    do: {{kind, meta, [nil | rest]}, acc}

  # A typespec names functions too; it is skipped entirely.
  defp visit({:@, _, [{attr, _, _}]}, acc, _file, _attrs) when attr in @type_attributes,
    do: {nil, acc}

  defp visit({{:., _, [:telemetry, fun]}, meta, _args} = node, acc, file, _attrs)
       when fun in [:execute, :span] do
    {node, add(acc, :raw_calls, {file, meta[:line], fun})}
  end

  defp visit(
         {{:., _, [{:__aliases__, _, [:Kanban, :Telemetry]}, fun]}, meta, args} = node,
         acc,
         file,
         attrs
       )
       when fun in [:emit, :span] and length(args) in [3, 4] do
    site = site(file, meta, fun, resolve(hd(args), attrs), telemetry_keys(fun, args))
    {node, add(acc, :sites, site)}
  end

  defp visit(
         {{:., _, [{:__aliases__, _, aliases}, :event]}, meta, [action | rest]} = node,
         acc,
         file,
         _attrs
       ) do
    if List.last(aliases) == :AuditLog do
      site = site(file, meta, :audit, action_name(:audit, action), keys(List.first(rest, [])))
      {node, add(acc, :sites, site)}
    else
      {node, acc}
    end
  end

  defp visit({:emit_telemetry, meta, [_conn, action, metadata]} = node, acc, file, _attrs),
    do: {node, add_api_site(acc, file, meta, action, metadata)}

  defp visit(
         {{:., _, [_module, :emit_telemetry]}, meta, [_conn, action, metadata]} = node,
         acc,
         file,
         _attrs
       ),
       do: {node, add_api_site(acc, file, meta, action, metadata)}

  defp visit(node, acc, _file, _attrs), do: {node, acc}

  defp add(acc, key, item), do: Map.update!(acc, key, &[item | &1])

  defp add_api_site(acc, file, meta, action, metadata),
    do: add(acc, :sites, site(file, meta, :api, action_name(:api, action), keys(metadata)))

  defp site(file, meta, kind, name, keys),
    do: %{file: file, line: meta[:line], kind: kind, name: name, keys: keys}

  # emit(event, measurements, metadata, ...) and span(prefix, metadata, fun, ...)
  defp telemetry_keys(:emit, [_name, _measurements, metadata | _]), do: keys(metadata)
  defp telemetry_keys(:emit, [_name, _measurements]), do: []
  defp telemetry_keys(:span, [_prefix, metadata | _]), do: keys(metadata)

  defp action_name(family, action) when is_atom(action), do: [:kanban, family, action]
  defp action_name(_family, _action), do: :dynamic

  defp resolve(name, attrs) do
    case name do
      {:@, _, [{attr, _, nil}]} -> Map.get(attrs, attr, :dynamic)
      list when is_list(list) -> if Enum.all?(list, &is_atom/1), do: list, else: :dynamic
      _other -> :dynamic
    end
  end

  defp keys({:%{}, _, pairs}), do: pair_keys(pairs)
  defp keys(list) when is_list(list), do: pair_keys(list)
  defp keys(_other), do: :unknown

  defp pair_keys(pairs) do
    if Enum.all?(pairs, &match?({key, _value} when is_atom(key), &1)),
      do: Enum.map(pairs, &elem(&1, 0)),
      else: :unknown
  end

  # Module attributes whose value is a literal list of atoms, by name.
  defp literal_attributes(ast) do
    {_ast, attrs} = Macro.prewalk(ast, %{}, &collect_attribute/2)
    attrs
  end

  defp collect_attribute({:@, _, [{attr, _, [value]}]} = node, acc) when is_list(value) do
    if Enum.all?(value, &is_atom/1),
      do: {node, Map.put(acc, attr, value)},
      else: {node, acc}
  end

  defp collect_attribute(node, acc), do: {node, acc}
end
