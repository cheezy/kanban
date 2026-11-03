defmodule Kanban.Attachments.BlobCleanupWorker.Settings do
  @moduledoc """
  The settings and the clock of `Kanban.Attachments.BlobCleanupWorker`.

  Settings come from `config :kanban, Kanban.Attachments.BlobCleanupWorker`:

    * `:batch_size` — how many due tombstones one run takes, a positive
      integer (default #{200});
    * `:max_run_seconds` — how long a run keeps taking tombstones, a
      positive integer below the job's #{30}-minute timeout (default #{600}).

  `check!/1` runs at boot (`Kanban.Application.start/2`) and raises on a
  value that breaks those rules, so a typo stops the app rather than
  silently running with the default. A value changed at runtime is not
  checked again; `batch_size/1` and `budget_ms/1` fall back to the default
  for one and log a warning.

  A run's time is the current time, or a `"now"` ISO 8601 job argument when
  the app runs in the test environment (`config :kanban, :env, :test`). In
  any other environment the argument is ignored with a warning: a far-future
  "now" would make every pending upload's tombstone due. A malformed one is
  ignored with a warning too. The argument's value is never logged.
  """

  require Logger

  @default_batch_size 200
  @default_max_run_seconds 600
  @timeout_minutes 30
  @config "config :kanban, Kanban.Attachments.BlobCleanupWorker"

  @doc "The job timeout, in milliseconds: #{@timeout_minutes} minutes."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: :timer.minutes(@timeout_minutes)

  @doc """
  Raises `ArgumentError` when `settings` is not a keyword list or holds a
  `:batch_size` or `:max_run_seconds` that breaks the rules above; `:ok`
  otherwise. An absent setting is fine: it takes the default.
  """
  @spec check!(term()) :: :ok
  def check!(settings) do
    unless Keyword.keyword?(settings),
      do: raise(ArgumentError, "#{@config} must be a keyword list")

    Enum.each(
      [batch_size: &batch_size_problem/1, max_run_seconds: &budget_problem/1],
      fn {key, problem} -> check_setting!(settings, key, problem) end
    )
  end

  defp check_setting!(settings, key, problem) do
    with {:ok, value} <- Keyword.fetch(settings, key),
         message when is_binary(message) <- problem.(value) do
      raise ArgumentError, "#{@config}: #{key} #{message}"
    else
      _absent_or_valid -> :ok
    end
  end

  @doc "The batch size from `settings`, or the default with a warning when it is invalid."
  @spec batch_size(keyword()) :: pos_integer()
  def batch_size(settings),
    do: setting(settings, :batch_size, @default_batch_size, &batch_size_problem/1)

  @doc "The run's budget from `settings`, in milliseconds, or the default with a warning."
  @spec budget_ms(keyword()) :: pos_integer()
  def budget_ms(settings),
    do: setting(settings, :max_run_seconds, @default_max_run_seconds, &budget_problem/1) * 1000

  defp setting(settings, key, default, problem) do
    value = Keyword.get(settings, key, default)

    case problem.(value) do
      nil ->
        value

      message ->
        Logger.warning("attachment blob cleanup: #{key} #{message}; using #{default}")
        default
    end
  end

  defp batch_size_problem(value) when is_integer(value) and value > 0, do: nil
  defp batch_size_problem(_value), do: "must be a positive integer"

  defp budget_problem(value)
       when is_integer(value) and value > 0 and value < @timeout_minutes * 60,
       do: nil

  defp budget_problem(_value),
    do: "must be a positive integer below the job timeout of #{@timeout_minutes * 60} seconds"

  @doc """
  The run's time, with microsecond precision: the job's `"now"` argument in
  the `:test` environment `env`, else the current time.
  """
  @spec run_time(map(), atom() | nil) :: DateTime.t()
  def run_time(args, env), do: args |> now(env) |> usec()

  defp now(%{"now" => value}, :test), do: parse_now(value)
  defp now(%{"now" => _value}, _env), do: ignore_now("outside the test environment")
  defp now(_args, _env), do: DateTime.utc_now()

  defp parse_now(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> ignore_now("that is not an ISO 8601 time")
    end
  end

  defp parse_now(_value), do: ignore_now("that is not an ISO 8601 time")

  defp ignore_now(why) do
    Logger.warning(
      "attachment blob cleanup ignored a now job argument #{why} and used the current time"
    )

    DateTime.utc_now()
  end

  # delete_after is a microsecond column, so the run time keeps microsecond
  # precision.
  defp usec(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}
end
