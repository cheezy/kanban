defmodule Mix.Tasks.Kanban.BackfillChangedFiles do
  @shortdoc "Recomputes and re-uploads a review task's missing changed_files diff"

  @moduledoc """
  Restores the `changed_files` diff for a review task whose upload was lost in
  transit (task W1660). It recomputes the per-file diff from the local git
  clone and re-PUTs it through the existing
  `PUT /api/tasks/:id/changed_files` endpoint — the sole writer for the field.

  Because it re-uses the real endpoint, the upload is validated
  (`ChangedFilesTransport` → `CompletionValidation`/`PathSafety`, clean
  repo-relative paths, 500-line cap) and authorized (board-write) server-side,
  with no second validation path and no raw DB write.

  The server has no git repository, so the diff can only be recomputed
  client-side — run this from a clone whose history contains the task's commit.

  ## Usage

      STRIDE_API_URL=https://www.stridelikeaboss.com \\
      STRIDE_API_TOKEN=stride_... \\
      mix kanban.backfill_changed_files --task D110 --base <base-sha>

    * `--task` (required) — the task id or identifier to restore.
    * `--base` (required) — the git ref the diff is computed against (the
      commit immediately before the task's work, i.e. `git diff <base> -- file`).

  It refuses to overwrite a task that already has a valid `changed_files`
  (the "backfill only the empty ones" rule) — re-running is a safe no-op.
  """
  use Mix.Task

  alias Kanban.ChangedFiles.Backfill

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:req)

    args
    |> backfill()
    |> handle_result()
  end

  defp backfill(args) do
    with {:ok, ctx} <- prepare(args),
         :ok <- ensure_backfill_needed(ctx.remote) do
      do_backfill(ctx)
    end
  end

  defp prepare(args) do
    with {:ok, %{task: task, base: base}} <- parse_args(args),
         {:ok, config} <- resolve_config(),
         {:ok, remote} <- fetch_task(config, task) do
      {:ok, %{task: task, base: base, config: config, remote: remote}}
    end
  end

  defp handle_result(:ok), do: :ok
  defp handle_result({:skip, message}), do: Mix.shell().info(message)
  defp handle_result({:error, reason}), do: fail(reason)

  @doc """
  Resolves the API base URL and token from `STRIDE_API_URL` / `STRIDE_API_TOKEN`.

  Returns `{:ok, %{url, token}}` when both are set to non-empty values, or
  `{:error, {:missing_config, var}}` naming the first missing variable — the
  token is a secret and is never defaulted.
  """
  @spec resolve_config() :: {:ok, %{url: String.t(), token: String.t()}} | {:error, term()}
  def resolve_config do
    with {:ok, url} <- fetch_env("STRIDE_API_URL"),
         {:ok, token} <- fetch_env("STRIDE_API_TOKEN") do
      {:ok, %{url: String.trim_trailing(url, "/"), token: token}}
    end
  end

  defp fetch_env(var) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_config, var}}
    end
  end

  @doc """
  Whether `git diff --numstat` output describes a binary file.

  Git reports a binary file's added/removed counts as `-\\t-`, so a leading
  `-` in the first column marks the entry as binary.
  """
  @spec binary_numstat?(String.t()) :: boolean()
  def binary_numstat?(numstat) when is_binary(numstat) do
    case numstat |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      ["-" | _] -> true
      _ -> false
    end
  end

  defp parse_args(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [task: :string, base: :string])

    case {opts[:task], opts[:base]} do
      {task, base} when is_binary(task) and is_binary(base) ->
        {:ok, %{task: task, base: base}}

      _ ->
        {:error, :missing_args}
    end
  end

  defp fetch_task(config, task) do
    case req(config, "/api/tasks/#{task}") |> Req.get() do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, {:request_failed, reason}}
    end
  end

  defp ensure_backfill_needed(remote) do
    if Backfill.needs_backfill?(remote["changed_files"]) do
      :ok
    else
      {:skip, "#{remote["identifier"]} already has a changed_files diff — nothing to backfill."}
    end
  end

  defp do_backfill(%{config: config, task: task, base: base, remote: remote}) do
    entries =
      remote
      |> paths()
      |> Backfill.build_entries(git_diff_fun(base))

    envelope = Backfill.encode_envelope(entries)
    put_changed_files(config, task, envelope, remote["identifier"], length(entries))
  end

  defp put_changed_files(config, task, envelope, identifier, count) do
    url = "/api/tasks/#{task}/changed_files"

    case req(config, url) |> Req.merge(json: %{"changed_files" => envelope}) |> Req.put() do
      {:ok, %{status: 200}} ->
        Mix.shell().info("Backfilled #{identifier}: uploaded #{count} changed file(s).")
        :ok

      {:ok, %{status: status, body: body}} ->
        fail({:http, status, body})

      {:error, reason} ->
        fail({:request_failed, reason})
    end
  end

  defp paths(remote) do
    remote
    |> Map.get("actual_files_changed")
    |> parse_files()
  end

  defp parse_files(text) when is_binary(text) do
    text |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_files(_), do: []

  # Builds the injected diff callback the pure builder asks per path. Runs
  # `git diff` against `base` for each file: numstat first to spot binaries,
  # then the unified patch. Any git failure degrades to a path-only entry.
  defp git_diff_fun(base) do
    fn path ->
      case System.cmd("git", ["diff", "--numstat", base, "--", path], stderr_to_stdout: true) do
        {numstat, 0} ->
          if binary_numstat?(numstat), do: :binary, else: unified_diff(base, path)

        _ ->
          :error
      end
    end
  end

  defp unified_diff(base, path) do
    case System.cmd("git", ["diff", base, "--", path], stderr_to_stdout: true) do
      {diff, 0} -> {:ok, diff}
      _ -> :error
    end
  end

  defp req(config, path) do
    Req.new(
      url: "#{config.url}#{path}",
      headers: [{"authorization", "Bearer #{config.token}"}]
    )
  end

  defp fail({:missing_config, var}) do
    Mix.shell().error("#{var} must be set (see .stride_auth.md) to run the backfill.")
    exit({:shutdown, 1})
  end

  defp fail(:missing_args) do
    Mix.shell().error("Usage: mix kanban.backfill_changed_files --task <id> --base <git-ref>")
    exit({:shutdown, 1})
  end

  defp fail({:http, status, body}) do
    Mix.shell().error("API returned #{status}: #{inspect(body)}")
    exit({:shutdown, 1})
  end

  defp fail({:request_failed, reason}) do
    Mix.shell().error("Request failed: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
