defmodule Kanban.Workspaces.Export.Importer.Repairs do
  @moduledoc """
  Brings rows that this app wrote before a validation existed within today's
  limits, so `Kanban.Workspaces.Export.Importer` can restore an archive that
  holds them instead of refusing it whole (decided 2026-10-20).

  Two rules are newer than the data they check:

    * a comment's `content` has been capped at
      `Kanban.Tasks.TaskComment.content_max_length/0` characters only since
      W2208 (2026-10-07); older comments can be longer, and `comment_content/1`
      shortens them to the cap;
    * a task's `required_capabilities` have been limited to
      `Kanban.Tasks.Task.valid_capabilities/0` only since 2026-01-08; older
      tasks can name others, and `capabilities/1` drops them.

  Each function returns the value to import and what it changed, so the
  importer can list every repair in its report. A value of any other shape is
  returned unchanged, for the changeset to refuse as before.
  """

  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

  @doc """
  Returns `{content, :ok}`, or `{shortened, {:shortened, original_length}}`
  when `content` is longer than the comment cap. Lengths are counted in
  codepoints, as the comment changeset counts them. Text that is not valid
  UTF-8, and anything that is not a string, is returned unchanged.

  ## Examples

      iex> comment_content("short")
      {"short", :ok}

  """
  @spec comment_content(term()) :: {term(), :ok | {:shortened, pos_integer()}}
  def comment_content(content) when is_binary(content) do
    max = TaskComment.content_max_length()
    codepoints = if String.valid?(content), do: String.codepoints(content), else: []
    length = length(codepoints)

    if length > max,
      do: {codepoints |> Enum.take(max) |> Enum.join(), {:shortened, length}},
      else: {content, :ok}
  end

  def comment_content(content), do: {content, :ok}

  @doc """
  Returns `{kept, dropped_count}`: the capabilities of `capabilities` that are
  still valid, in their order, and how many were dropped. Anything other than
  a list of strings is returned unchanged with a count of 0.

  ## Examples

      iex> capabilities(["testing", "pubsub_integration"])
      {["testing"], 1}

  """
  @spec capabilities(term()) :: {term(), non_neg_integer()}
  def capabilities(capabilities) when is_list(capabilities) do
    if Enum.all?(capabilities, &is_binary/1) do
      valid = Task.valid_capabilities()
      {kept, dropped} = Enum.split_with(capabilities, &(&1 in valid))
      {kept, length(dropped)}
    else
      {capabilities, 0}
    end
  end

  def capabilities(capabilities), do: {capabilities, 0}
end
