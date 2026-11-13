defmodule Kanban.Repo.QueryLogger do
  @moduledoc """
  Logs `Kanban.Repo` queries with the plaintext of encrypted fields redacted.

  Ecto's own query log prints each query's cast params, and for a field typed
  `Kanban.Encryption.EncryptedBinary` or `TolerantEncryptedBinary` the cast
  param is the plaintext secret (the dumped param sent to the database is the
  ciphertext). At the `:debug` level dev and test run at, that wrote
  destination URLs, credentials, signing secrets, SSO client secrets and TOTP
  secrets to the log.

  So `Kanban.Repo.init/2` turns Ecto's logging off (`log: false`) and
  `attach/1`, called when `Kanban.Application` starts, logs the same
  `QUERY OK ...` line from the `[:kanban, :repo, :query]` telemetry event,
  which Ecto emits whatever the `:log` option says. The event itself is
  untouched: other handlers still receive the plaintext `cast_params` they
  always did. Only the logged copy is redacted.

  ## What is redacted

  Detection is by value, never by field name: a param is one of ours when it
  decrypts with one of the app's two at-rest ciphers, `Kanban.Encryption`
  (behind `EncryptedBinary` and `TolerantEncryptedBinary`) or
  `Kanban.Integrations.SecretBox` (behind `Kanban.Integrations.EncryptedString`).
  Every cast param equal to such a plaintext, and every such ciphertext, is
  logged as `"**redacted**"` — the marker `Ecto.Changeset` uses for
  `redact: true` fields. So a new field of any of those types is covered
  without a list to maintain, and the position of the param in the query does
  not matter; a new cipher needs an entry in `decryptors/0`. Every other param
  is logged as Ecto logs it, and `nil` stays `nil`.

  If decryption raises (for example, no key is configured), no cast param is
  logged at all: the dumped params are logged instead, with every value that
  has the ciphertext shape replaced, so neither a plaintext nor a ciphertext's
  key version reaches the log.

  ## Level and exceptions

  Queries are logged at the Repo's configured `:log` level (Ecto's default,
  `:debug`, when it is unset); `log: false` in the Repo config attaches
  nothing. Queries whose caller manages its own logging are skipped, as Ecto
  would skip them: Oban's (its `log` option, `false` by default) and the
  migrator's `schema_migrations` queries. A caller that passes its own
  `log: <level>` to a single Repo call is still logged by Ecto itself, without
  redaction; nothing in this app does so.
  """

  alias Kanban.Encryption
  alias Kanban.Integrations.SecretBox

  require Logger

  @handler_id {__MODULE__, :redacted_query_log}
  @event [:kanban, :repo, :query]
  @mark "**redacted**"
  @default_stacktrace_mfa {Ecto.Adapters.SQL, :first_non_ecto_stacktrace, [1]}

  @doc """
  The Repo config with Ecto's own query logging turned off, so that the
  handler `attach/1` adds is the only thing that logs queries.
  """
  @spec disable_ecto_logging(keyword()) :: keyword()
  def disable_ecto_logging(repo_config), do: Keyword.put(repo_config, :log, false)

  @doc """
  Attaches the handler that logs queries with encrypted values redacted, at
  the level `repo_config`'s `:log` names (`:debug` when absent). With
  `log: false` it attaches nothing. Attaching again is a no-op.
  """
  @spec attach(keyword()) :: :ok
  def attach(repo_config \\ Application.get_env(:kanban, Kanban.Repo, [])) do
    case Keyword.get(repo_config, :log, :debug) do
      false ->
        :ok

      level ->
        config = %{
          level: level,
          stacktrace_mfa: Keyword.get(repo_config, :log_stacktrace_mfa, @default_stacktrace_mfa)
        }

        case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, config) do
          :ok -> :ok
          {:error, :already_exists} -> :ok
        end
    end
  end

  @doc "Detaches the handler `attach/1` added. Detaching twice is a no-op."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  # Public only so :telemetry can call it without a local-function warning.
  # It must never raise: :telemetry detaches a handler that does.
  def handle_event(@event, measurements, metadata, config) do
    unless caller_logs_itself?(metadata) do
      Logger.log(
        config.level,
        fn -> log_iodata(measurements, metadata, config) end,
        ansi_color: sql_color(Map.get(metadata, :query))
      )
    end

    :ok
  end

  @doc """
  The params to log for a query: `cast_params` (or, when it is `nil`, the
  dumped `params`) with every encrypted value and its plaintext replaced by
  `"**redacted**"`. Lists (array params) are redacted element by element.
  When there are no `cast_params` (a raw `Repo.query/3`), every
  ciphertext-shaped value is replaced too, decryptable or not, so no
  ciphertext's key version is logged.

  ## Examples

      iex> ciphertext = Kanban.Encryption.encrypt("s3cret")
      iex> Kanban.Repo.QueryLogger.redact_params(["s3cret", "name", nil], [ciphertext, "name", nil])
      ["**redacted**", "name", nil]

      iex> Kanban.Repo.QueryLogger.redact_params(["name", 1], ["name", 1])
      ["name", 1]

  """
  @spec redact_params(list() | nil, list()) :: list()
  def redact_params(cast_params, params) when is_list(params) do
    params
    |> decrypted_pairs()
    |> redact_with(cast_params, params)
  end

  def redact_params(cast_params, _params), do: cast_params

  defp redact_with({:ok, pairs}, cast_params, _params) when is_list(cast_params),
    do: replace(cast_params, secret_predicate(pairs))

  defp redact_with({:ok, pairs}, _cast_params, params),
    do: replace(params, secret_or_ciphertext(secret_predicate(pairs)))

  defp redact_with(:error, _cast_params, params), do: replace(params, &ciphertext?/1)

  defp secret_or_ciphertext(secret?), do: &(secret?.(&1) or ciphertext?(&1))

  defp decrypted_pairs(params) do
    pairs =
      for value <- flatten(params),
          {shape?, decrypt} <- decryptors(),
          shape?.(value),
          {:ok, plaintext} <- [decrypt.(value)],
          do: {value, plaintext}

    {:ok, pairs}
  rescue
    _exception -> :error
  end

  # Every at-rest cipher an Ecto type in this app dumps through: a cheap shape
  # check, then the decrypt that proves the value is ours.
  defp decryptors do
    [
      {&Encryption.ciphertext?/1, &Encryption.decrypt/1},
      {&secret_box_ciphertext?/1, &SecretBox.decrypt/1}
    ]
  end

  # Plug.Crypto.MessageEncryptor, which SecretBox uses, prefixes its output.
  defp secret_box_ciphertext?("XCP." <> _rest), do: true
  defp secret_box_ciphertext?(_value), do: false

  defp ciphertext?(value),
    do: Enum.any?(decryptors(), fn {shape?, _decrypt} -> shape?.(value) end)

  defp secret_predicate([]), do: fn _value -> false end

  defp secret_predicate(pairs) do
    secrets =
      pairs
      |> Enum.flat_map(fn {ciphertext, plaintext} -> [ciphertext, plaintext] end)
      |> MapSet.new()

    &(is_binary(&1) and MapSet.member?(secrets, &1))
  end

  defp flatten(params), do: Enum.flat_map(params, &flatten_value/1)

  defp flatten_value(list) when is_list(list), do: flatten(list)
  defp flatten_value(value), do: [value]

  defp replace(params, secret?) when is_list(params),
    do: Enum.map(params, &replace_value(&1, secret?))

  defp replace(params, _secret?), do: params

  defp replace_value(list, secret?) when is_list(list), do: replace(list, secret?)

  defp replace_value(value, secret?) do
    if secret?.(value), do: @mark, else: value
  end

  defp caller_logs_itself?(%{options: options}) when is_list(options) do
    Keyword.keyword?(options) and
      (Keyword.has_key?(options, :oban_conf) or Keyword.get(options, :schema_migration) == true)
  end

  defp caller_logs_itself?(_metadata), do: false

  # The line Ecto.Adapters.SQL logs, with redacted params. Any failure while
  # redacting logs the dumped params with ciphertext-shaped values replaced.
  defp log_iodata(measurements, metadata, config) do
    [
      header(measurements, metadata),
      ?\n,
      to_string(Map.get(metadata, :query, "")),
      ?\s,
      inspect(safe_log_params(metadata), charlists: false),
      stacktrace(Map.get(metadata, :stacktrace), Map.get(metadata, :repo), config.stacktrace_mfa)
    ]
  end

  defp header(measurements, metadata) do
    [
      "QUERY ",
      ok_error(Map.get(metadata, :result)),
      source(Map.get(metadata, :source)),
      log_time("db", measurements, :query_time, true),
      log_time("decode", measurements, :decode_time, false),
      log_time("queue", measurements, :queue_time, false),
      log_time("idle", measurements, :idle_time, true)
    ]
  end

  defp safe_log_params(metadata) do
    params = Map.get(metadata, :params) || []

    try do
      redact_params(Map.get(metadata, :cast_params), params)
    rescue
      _exception -> replace(params, &ciphertext?/1)
    end
  end

  defp ok_error({:ok, _result}), do: "OK"
  defp ok_error(_error), do: "ERROR"

  defp source(nil), do: ""
  defp source(source), do: " source=#{inspect(source)}"

  defp log_time(label, measurements, key, force?) do
    case measurements do
      %{^key => time} when is_integer(time) ->
        us = System.convert_time_unit(time, :native, :microsecond)
        ms = div(us, 100) / 10

        if force? or ms > 0,
          do: [?\s, label, ?=, :io_lib_format.fwrite_g(ms), ?m, ?s],
          else: []

      %{} ->
        []
    end
  end

  defp stacktrace([_ | _] = stacktrace, repo, {module, function, args}) do
    module
    |> apply(function, [stacktrace, %{repo: repo} | args])
    |> Enum.with_index(&stacktrace_entry/2)
  end

  defp stacktrace(_stacktrace, _repo, _mfa), do: []

  defp stacktrace_entry({module, function, arity, info}, index) do
    [
      ?\n,
      IO.ANSI.light_black(),
      if(index == 0, do: "↳ ", else: "  "),
      Exception.format_mfa(module, function, arity),
      stacktrace_info(info),
      IO.ANSI.reset()
    ]
  end

  defp stacktrace_info([file: file, line: line] ++ _rest),
    do: [", at: ", file, ?:, Integer.to_string(line)]

  defp stacktrace_info(_info), do: []

  defp sql_color("SELECT" <> _), do: :cyan
  defp sql_color("ROLLBACK" <> _), do: :red
  defp sql_color("LOCK" <> _), do: :white
  defp sql_color("INSERT" <> _), do: :green
  defp sql_color("UPDATE" <> _), do: :yellow
  defp sql_color("DELETE" <> _), do: :red
  defp sql_color("begin" <> _), do: :magenta
  defp sql_color("commit" <> _), do: :magenta
  defp sql_color(_query), do: nil
end
