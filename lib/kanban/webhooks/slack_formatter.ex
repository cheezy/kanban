defmodule Kanban.Webhooks.SlackFormatter do
  @moduledoc """
  Turns a webhook envelope (`Kanban.Webhooks.Payload`) into a Slack
  incoming-webhook message (W2227): a plain `text` fallback for
  notifications plus Block Kit `blocks` naming the task's identifier, title,
  event and column with links to the task and the board.

  Every value that comes from the board (titles, board and column names,
  identifiers) goes through `escape/1`, so a title cannot inject a Slack
  link, a mention such as `<!channel>`, or formatting control characters.
  """

  @max_title 200

  @labels %{
    "task.created" => "created",
    "task.updated" => "updated",
    "task.moved" => "moved",
    "task.claimed" => "claimed",
    "task.unclaimed" => "unclaimed",
    "task.completed" => "completed",
    "task.moved_to_review" => "moved to review",
    "task.reviewed" => "reviewed",
    "task.deleted" => "deleted"
  }

  @doc "The Slack message for an envelope."
  @spec format(map()) :: map()
  def format(%{"event" => "ping", "board" => board}) do
    text = "Stride test message for board #{escape(board["name"])}"

    %{
      "text" => text,
      "blocks" => [section("#{text}: #{link(board["url"], "open the board")}")]
    }
  end

  def format(%{"event" => event, "board" => board, "task" => task}) do
    label = Map.get(@labels, event, event)
    identifier = escape(task["identifier"])
    title = task["title"] |> truncate() |> escape()
    column = escape(get_in(task, ["column", "name"]))

    %{
      "text" => "#{identifier} #{title} was #{label}",
      "blocks" => [
        section("`#{identifier}` #{link(task["url"], title)} was *#{label}*"),
        context([
          "Board: #{link(board["url"], escape(board["name"]))}",
          "Column: #{column}",
          "Event: `#{escape(event)}`"
        ])
      ]
    }
  end

  @doc """
  Escapes the three characters Slack treats as control characters in
  message text (`&`, `<` and `>`). `nil` becomes an empty string.
  """
  @spec escape(String.t() | nil) :: String.t()
  def escape(nil), do: ""

  def escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp truncate(nil), do: nil

  defp truncate(title) do
    if String.length(title) > @max_title,
      do: String.slice(title, 0, @max_title - 1) <> "…",
      else: title
  end

  defp link(url, text), do: "<#{url}|#{text}>"

  defp section(text), do: %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => text}}

  defp context(lines) do
    %{"type" => "context", "elements" => Enum.map(lines, &%{"type" => "mrkdwn", "text" => &1})}
  end
end
