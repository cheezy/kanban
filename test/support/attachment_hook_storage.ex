defmodule Kanban.AttachmentHookStorage do
  @moduledoc """
  A test storage adapter that delegates to `Kanban.Attachments.Storage.Local`
  and reports each put and delete to the calling process as
  `{:storage_put, key}` and `{:storage_deleted, key}`. A test can replace a
  put with `Process.put(:on_put, fun)` (`fun.(key, source, opts)`) and a
  delete's result with `Process.put(:delete_result, result)`. The storage
  facade calls the adapter in the caller's process, so the process
  dictionary is the test's own.

  `use_hook_storage/0` installs it for one test and restores the previous
  adapter when the test exits; such tests must be `async: false`.
  """

  @behaviour Kanban.Attachments.Storage

  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.Storage.Local

  @impl true
  def put(key, source, opts) do
    send(self(), {:storage_put, key})

    case Process.get(:on_put) do
      nil -> Local.put(key, source, opts)
      fun -> fun.(key, source, opts)
    end
  end

  @impl true
  def stream(key), do: Local.stream(key)

  @impl true
  def delete(key) do
    send(self(), {:storage_deleted, key})

    case Process.get(:delete_result) do
      nil -> Local.delete(key)
      result -> result
    end
  end

  @impl true
  def exists(key), do: Local.exists(key)

  @doc "Makes this the storage adapter until the calling test exits."
  def use_hook_storage do
    previous = Application.get_env(:kanban, Storage)
    Application.put_env(:kanban, Storage, adapter: __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:kanban, Storage, previous),
        else: Application.delete_env(:kanban, Storage)
    end)
  end
end
