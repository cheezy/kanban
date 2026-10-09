defmodule Kanban.Webhooks.Payload do
  @moduledoc """
  Builds the JSON envelope a webhook delivery carries (W2227).

  The envelope is built once, when the event is emitted, and stored in the
  delivery job's args, so a retry sends exactly what the first attempt sent
  and a deleted task can still be described:

      %{
        "id" => "evt_<uuid>",
        "version" => 1,
        "event" => "task.moved",
        "occurred_at" => "2026-10-09T17:10:20Z",
        "board" => %{"id" => 1, "name" => "...", "url" => "https://.../boards/1"},
        "task" => %{"id" => 5, "identifier" => "W12", "title" => "...", ...}
      }

  The task part is an explicit allow-list (`@task_fields`) plus the column
  and a link: ids, the identifier, the title, the agent names that created
  and completed the task (`created_by_agent`, `completed_by_agent`), and
  enum, boolean and timestamp fields. The title, the two agent names, the
  column name and the envelope's board name are the only free text sent.
  Any field not on the list is withheld, among them the description,
  completion notes and summary, review notes, changed files, and the
  explorer and reviewer results, so a receiver gets enough to identify the
  task and follow the link but not its working detail.
  """

  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @version 1

  @task_fields ~w(
    id identifier title type status priority complexity needs_review
    review_status parent_id assigned_to_id created_by_agent completed_by_agent
    claimed_at completed_at reviewed_at inserted_at updated_at
  )a

  @doc "The task fields an envelope may carry."
  def task_fields, do: @task_fields

  @doc """
  Builds the envelope for `event` (a public event name) about `task`. The
  column and board are loaded fresh from the task's `column_id`, so a moved
  task whose preloaded column is stale reports the column it is in. Returns
  `{:error, :no_column}` for a task that is not on a board.
  """
  @spec build(String.t(), Task.t()) :: {:ok, map()} | {:error, :no_column}
  def build(event, %Task{} = task) when is_binary(event) do
    case Repo.preload(task, [column: :board], force: true) do
      %Task{column: %{board: %Board{} = board} = column} = loaded ->
        {:ok, envelope(event, board, task_data(loaded, column, board))}

      _no_column ->
        {:error, :no_column}
    end
  end

  @doc "Builds the envelope of a `ping` (test) delivery for `board`."
  @spec ping(Board.t()) :: map()
  def ping(%Board{} = board), do: envelope("ping", board, nil)

  @doc "The board's URL in this app."
  @spec board_url(Board.t() | integer()) :: String.t()
  def board_url(%Board{id: id}), do: board_url(id)
  def board_url(board_id), do: KanbanWeb.Endpoint.url() <> "/boards/#{board_id}"

  defp envelope(event, board, task) do
    %{
      "id" => "evt_" <> Ecto.UUID.generate(),
      "version" => @version,
      "event" => event,
      "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "board" => %{"id" => board.id, "name" => board.name, "url" => board_url(board)},
      "task" => task
    }
  end

  defp task_data(task, column, board) do
    task
    |> Map.take(@task_fields)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), encode(value)} end)
    |> Map.put("column", %{"id" => column.id, "name" => column.name})
    |> Map.put("url", board_url(board) <> "/tasks/#{task.id}/edit")
  end

  defp encode(nil), do: nil
  defp encode(value) when is_boolean(value), do: value
  defp encode(value) when is_atom(value), do: Atom.to_string(value)
  defp encode(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp encode(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp encode(value), do: value
end
