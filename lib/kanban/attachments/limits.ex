defmodule Kanban.Attachments.Limits do
  @moduledoc """
  The size and count limits on attachments.

  Each limit is read from `config :kanban, Kanban.Attachments.Limits` every
  time it is asked for, never captured at compile time, so a test or an
  operator changing the config takes effect at once. `config/runtime.exs`
  writes the keys from the `ATTACHMENTS_MAX_FILE_MB`,
  `ATTACHMENTS_MAX_FILES_PER_TASK` and `ATTACHMENTS_ORG_QUOTA_GB` environment
  variables; see `docs/attachments.md`. A key that is not configured falls back
  to its default:

    * `max_file_bytes` — 26,214,400 bytes (25 MiB) per file.
    * `max_files_per_task` — 20 files on one task.
    * `organization_quota_bytes` — 10,737,418,240 bytes (10 GiB) for every
      file in one Organization.
  """

  @defaults [
    max_file_bytes: 26_214_400,
    max_files_per_task: 20,
    organization_quota_bytes: 10_737_418_240
  ]

  @doc "The largest single file, in bytes."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: get(:max_file_bytes)

  @doc "How many files one task can hold."
  @spec max_files_per_task() :: pos_integer()
  def max_files_per_task, do: get(:max_files_per_task)

  @doc "The total size of every file in one Organization, in bytes."
  @spec organization_quota_bytes() :: pos_integer()
  def organization_quota_bytes, do: get(:organization_quota_bytes)

  defp get(key) do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
