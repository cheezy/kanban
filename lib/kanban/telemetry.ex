defmodule Kanban.Telemetry do
  @moduledoc """
  The one path for emitting kanban telemetry events.

  `emit/3` and `span/3` wrap `:telemetry.execute/3` and `:telemetry.span/3`.
  Before anything is emitted they look the event up in
  `Kanban.Telemetry.Catalog` and filter its metadata:

    * **Forbidden keys are always dropped**, in every environment, even when a
      catalog entry declares them by mistake. `forbidden_key?/1` decides which
      keys are forbidden: personal data such as `email`, `ip`, `title`,
      `description` and `body`, and credential-shaped keys such as `token`,
      `password` or `secret`. A key ending in `_id` (`token_id`) is a row id,
      not a secret, and is allowed.
    * **Undeclared keys** - keys the entry does not list - are dropped.
    * Every drop is logged as a warning and reported as a
      `[:kanban, :telemetry, :metadata_dropped]` event. Both carry key names
      only, never values.

  ## Strict mode

  When strict mode is on, an undeclared event or an undeclared metadata key
  raises `ArgumentError` instead of being dropped, so a mistake fails the test
  that made it. Strict mode is read at runtime from

      config :kanban, Kanban.Telemetry, strict: true

  and is set only in `config/test.exs`. Outside strict mode `emit/3` never
  raises: an undeclared event is logged and skipped, an undeclared key is
  dropped, and metadata that is neither a map nor a keyword list is treated as
  empty. The `strict: false` option turns strict mode off for one call; no
  option can turn it on, so production code can never be made to raise.

  ## Spans and exceptions

  `span/3` keeps `:telemetry.span/3` semantics, so `Telemetry.Metrics`
  duration summaries work unchanged. Its start and stop metadata are filtered
  like `emit/3` metadata. On an exception, `:telemetry` adds its standard
  `kind`, `reason` and `stacktrace` keys to the exception event. They are not
  filtered, and `reason` can quote data from the failed operation, so an
  exporter that ships events out of the app must not send `reason` or
  `stacktrace` verbatim.

  ## Example

      Kanban.Telemetry.emit([:kanban, :task, :changed_files_missing], %{count: 1},
        task_id: task.id, identifier: task.identifier, board_id: board_id)
  """

  alias Kanban.Telemetry.Catalog

  require Logger

  @dropped_event [:kanban, :telemetry, :metadata_dropped]

  # Exact key names that carry personal data.
  @forbidden_keys ~w(email ip ip_address remote_ip title description body token)

  # A key is also forbidden when its name contains one of these, so
  # credential-shaped keys (reset_token, api_key, otp_secret) are caught too.
  @forbidden_substrings ~w(email password secret token authorization api_key)

  # Keys ending in `_id` are row ids (token_id), exempt from the substring rule.
  @id_suffix "_id"

  @typedoc "Options for `emit/4` and `span/4`."
  @type option :: {:strict, false} | {:catalog, [Catalog.entry()]}

  @typedoc "Measurements or metadata, as a map or keyword list."
  @type fields :: map() | keyword()

  @doc """
  Emits a catalogued event with `:telemetry.execute/3`.

  `measurements` and `metadata` may be maps or keyword lists. Metadata keys are
  filtered as described in the moduledoc. Returns `:ok`.

  Options:

    * `:strict` - pass `false` to turn strict mode off for this call.
    * `:catalog` - a list of entries to use instead of
      `Kanban.Telemetry.Catalog`, for tests and tools.
  """
  @spec emit([atom()], fields(), fields(), [option()]) :: :ok
  def emit(event, measurements, metadata \\ %{}, opts \\ []) do
    strict? = strict?(opts)

    case lookup(event, :event, opts) do
      {:ok, entry} ->
        measurements = normalize(measurements)
        metadata = filter_metadata(entry, metadata, strict?)
        :telemetry.execute(event, measurements, metadata)

      :error ->
        undeclared(event, :event, strict?)
    end
  end

  @doc """
  Runs `fun` inside a catalogued span, with `:telemetry.span/3` semantics.

  `fun` takes no arguments and returns `{result, stop_metadata}` or
  `{result, extra_stop_measurements, stop_metadata}`. `span/3` returns
  `result`. The start event gets the filtered `metadata`, and the stop event
  gets the filtered `stop_metadata`. If `fun` raises, throws or exits, an
  exception event is emitted and the error is re-raised.

  Takes the same options as `emit/4`. In strict mode an undeclared span raises
  before `fun` runs; otherwise `fun` still runs and nothing is emitted.
  """
  @spec span([atom()], fields(), (-> {result, fields()} | {result, map(), fields()}), [
          option()
        ]) :: result
        when result: term()
  def span(prefix, metadata, fun, opts \\ []) when is_function(fun, 0) do
    strict? = strict?(opts)
    found = lookup(prefix, :span, opts)
    do_span(found, prefix, metadata, fun, strict?)
  end

  @doc """
  Returns `true` when `key` names data that must never reach telemetry.

  Matches an exact personal-data name (`email`, `ip`, `ip_address`,
  `remote_ip`, `title`, `description`, `body`, `token`) or a name containing a
  credential-shaped substring (`email`, `password`, `secret`, `token`,
  `authorization`, `api_key`) unless it ends in `_id`. Atom and string keys are
  both checked, case-insensitively.
  """
  @spec forbidden_key?(term()) :: boolean()
  def forbidden_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> forbidden_key?()
  end

  def forbidden_key?(key) when is_binary(key) do
    name = String.downcase(key)
    name in @forbidden_keys or credential_shaped?(name)
  end

  def forbidden_key?(_key), do: false

  defp credential_shaped?(name) do
    not String.ends_with?(name, @id_suffix) and
      Enum.any?(@forbidden_substrings, &String.contains?(name, &1))
  end

  # Options can only turn strict mode off, never on.
  defp strict?(opts) do
    configured = Application.get_env(:kanban, __MODULE__, [])
    configured[:strict] == true and Keyword.get(opts, :strict, true) != false
  end

  defp lookup(name, kind, opts) do
    case find_entry(name, opts[:catalog]) do
      {:ok, %{kind: ^kind} = entry} -> {:ok, entry}
      _other -> :error
    end
  end

  defp find_entry(name, nil), do: Catalog.fetch(name)

  defp find_entry(name, catalog) when is_list(catalog) do
    case Enum.find(catalog, &(&1.name == name)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  defp undeclared(name, kind, true = _strict?) do
    raise ArgumentError,
          "telemetry #{kind} #{inspect(name)} is not declared in Kanban.Telemetry.Catalog"
  end

  defp undeclared(name, kind, false = _strict?) do
    Logger.warning("Skipped telemetry #{kind} #{inspect(name)}: not declared in the catalog")
    :ok
  end

  defp do_span({:ok, entry}, prefix, metadata, fun, strict?) do
    start_metadata = filter_metadata(entry, metadata, strict?)
    :telemetry.span(prefix, start_metadata, fn -> run_span(fun, entry, strict?) end)
  end

  defp do_span(:error, prefix, _metadata, fun, strict?) do
    undeclared(prefix, :span, strict?)
    result = fun.()
    span_result(result)
  end

  defp run_span(fun, entry, strict?) do
    case fun.() do
      {result, stop_metadata} ->
        {result, filter_metadata(entry, stop_metadata, strict?)}

      {result, extra_measurements, stop_metadata} ->
        measurements = normalize(extra_measurements)
        {result, measurements, filter_metadata(entry, stop_metadata, strict?)}
    end
  end

  defp span_result({result, _stop_metadata}), do: result
  defp span_result({result, _extra_measurements, _stop_metadata}), do: result

  defp filter_metadata(entry, metadata, strict?) do
    groups = partition(entry, metadata)

    ensure_declared!(entry.name, groups.undeclared, strict?)
    report(entry.name, :forbidden, groups.forbidden)
    report(entry.name, :undeclared, groups.undeclared)

    Map.new(groups.kept)
  end

  defp partition(entry, metadata) do
    allowed = Map.new(entry.metadata, &{Atom.to_string(&1), &1})
    initial = %{kept: [], forbidden: [], undeclared: []}

    metadata
    |> normalize()
    |> Enum.reduce(initial, &classify(&1, &2, allowed))
  end

  defp classify({key, value}, groups, allowed) do
    name = key_name(key)

    case classify_key(key, name, allowed) do
      {:kept, atom} -> Map.update!(groups, :kept, &[{atom, value} | &1])
      group -> Map.update!(groups, group, &[name | &1])
    end
  end

  defp classify_key(key, name, allowed) do
    if forbidden_key?(key) do
      :forbidden
    else
      allowed
      |> Map.fetch(name)
      |> declared()
    end
  end

  defp declared({:ok, atom}), do: {:kept, atom}
  defp declared(:error), do: :undeclared

  defp ensure_declared!(_event, [], _strict?), do: :ok
  defp ensure_declared!(_event, _names, false = _strict?), do: :ok

  defp ensure_declared!(event, names, true = _strict?) do
    keys = Enum.sort(names)

    raise ArgumentError,
          "telemetry event #{inspect(event)} got undeclared metadata keys #{inspect(keys)}"
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)

  defp report(_event, _reason, []), do: :ok

  defp report(event, reason, names) do
    keys = Enum.sort(names)

    Logger.warning(
      "Dropped #{reason} telemetry metadata keys #{inspect(keys)} from #{inspect(event)}"
    )

    count = length(keys)
    metadata = %{event_name: event, reason: reason, keys: keys}
    :telemetry.execute(@dropped_event, %{count: count}, metadata)
  end

  defp normalize(fields) when is_map(fields) and not is_struct(fields), do: fields

  defp normalize(fields) when is_list(fields) do
    for {key, value} <- fields, into: %{}, do: {key, value}
  end

  defp normalize(_fields), do: %{}
end
