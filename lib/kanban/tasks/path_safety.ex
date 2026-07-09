defmodule Kanban.Tasks.PathSafety do
  @moduledoc """
  Single source of truth for validating that a client-supplied file path is a
  safe *relative* path — no absolute paths, no `..` traversal segments, and no
  embedded null bytes.

  Both file-path boundaries on the tasks schema share this predicate so they
  cannot drift (D114): the `key_files[].file_path` embed validator
  (`Kanban.Schemas.Task.KeyFile`) and the `changed_files[].path` API check
  (`Kanban.Tasks.CompletionValidation`). A path that is stored and later treated
  as a real filesystem location by any consumer must not be able to escape the
  repository root.
  """

  @typedoc "Why a path was rejected."
  @type reason :: :not_a_string | :empty | :absolute | :traversal | :null_byte

  @doc """
  Validates a relative file path, returning `:ok` or `{:error, reason}`.

  Rejects (in order): non-strings, empty strings, absolute paths (leading `/`),
  any `..` segment (also catches backslash traversal `..\\`), and null bytes.

  ## Examples

      iex> Kanban.Tasks.PathSafety.validate("lib/kanban/tasks.ex")
      :ok

      iex> Kanban.Tasks.PathSafety.validate("../../etc/passwd")
      {:error, :traversal}

      iex> Kanban.Tasks.PathSafety.validate("/etc/shadow")
      {:error, :absolute}
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :empty}
      String.starts_with?(path, "/") -> {:error, :absolute}
      String.contains?(path, "..") -> {:error, :traversal}
      String.contains?(path, <<0>>) -> {:error, :null_byte}
      true -> :ok
    end
  end

  def validate(_path), do: {:error, :not_a_string}

  @doc """
  Boolean predicate form of `validate/1`: `true` only for a safe relative path.

  ## Examples

      iex> Kanban.Tasks.PathSafety.relative_safe?("lib/foo.ex")
      true

      iex> Kanban.Tasks.PathSafety.relative_safe?("../secret")
      false
  """
  @spec relative_safe?(term()) :: boolean()
  def relative_safe?(path), do: validate(path) == :ok
end
