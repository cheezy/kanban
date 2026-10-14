defmodule Kanban.Webhooks.DiscordFormatter do
  @moduledoc """
  Turns a webhook envelope (`Kanban.Webhooks.Payload`) into a Discord
  execute-webhook body: a short `content` fallback plus one embed naming the
  task's identifier and title (linked to the task), the event, the column and
  the board (linked to the board), and a ping message for "Send test".

  Discord renders markdown and resolves `@everyone`, `@here`, user, role and
  channel mentions, so:

    * every body carries `"allowed_mentions" => %{"parse" => []}`, which stops
      any mention in `content` or the embed from notifying anyone;
    * every value that comes from the board goes through `escape/1`, so a
      title cannot become a masked link, a bare autolinked URL, a mention or
      formatting;
    * only Stride-built URLs (`task["url"]`, `board["url"]` from the envelope)
      are ever used as link targets, and the body never sets `username` or
      `avatar_url`.

  Discord rejects a body over its limits with `400`: content 2000 characters,
  embed title 256, description 4096, field name 256, field value 1024 and
  6000 across the embed. Lengths here are counted in code points — never
  looser than a grapheme count — and text is only ever cut on a grapheme
  boundary, with an ellipsis. The per-field caps below keep the embed total
  near 3,400 characters (title 256, description under 80, field names 16,
  three values of at most 1024), so the 6000 total needs no separate budget.
  """

  @title_max 256
  @value_max 1024
  @label_max 64
  @ping_name_max 200
  @link_overhead 4
  @placeholder "—"

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

  @doc "The Discord execute-webhook body for an envelope."
  @spec format(map()) :: map()
  def format(%{"event" => "ping"} = envelope) do
    board = Map.get(envelope, "board")
    name = board |> board_name() |> fit(@ping_name_max) |> present()

    body("Stride test message for board #{name}", ping_embed(board))
  end

  def format(%{"event" => event} = envelope) do
    board = Map.get(envelope, "board")
    task = Map.get(envelope, "task")
    title = embed_title(task)
    label = label(event)

    body("#{title} was #{label}", task_embed(title, label, event, board, task))
  end

  @doc """
  Escapes everything Discord would treat as markdown, a masked link, a bare
  URL or a mention by putting a backslash before it, and collapses line
  breaks to spaces so no line can start a heading, list or quote. Discord
  hides the backslash, so the text renders literally. `nil` becomes an empty
  string.
  """
  @spec escape(String.t() | nil) :: String.t()
  def escape(nil), do: ""

  def escape(text) when is_binary(text) do
    text
    |> String.replace(~r/\r\n|[\r\n\x{85}\x{2028}\x{2029}]/u, " ")
    |> String.replace(~r/[\\`*_~|<>#\-+.\[\]()@:]/u, "\\\\\\0")
  end

  defp body(content, embed) do
    %{"content" => content, "embeds" => [embed], "allowed_mentions" => %{"parse" => []}}
  end

  defp ping_embed(board) do
    %{"title" => "Stride test message", "fields" => [field("Board", board_value(board))]}
    |> put_url(board_url(board))
  end

  defp task_embed(title, label, event, board, task) do
    %{
      "title" => title,
      "description" => "Task **#{label}**",
      "fields" => [
        field("Event", fit(event, @value_max)),
        field("Column", column_name(task)),
        field("Board", board_value(board))
      ]
    }
    |> put_url(task_url(task))
  end

  defp embed_title(task) do
    [task_value(task, "identifier"), task_value(task, "title")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> fit(@title_max)
    |> present("Untitled task")
  end

  defp label(event) do
    case Map.fetch(@labels, event) do
      {:ok, label} -> label
      :error -> event |> fit(@label_max) |> present()
    end
  end

  defp board_value(board) do
    name = board_name(board)

    case board_url(board) do
      nil -> fit(name, @value_max)
      url -> "[#{link_label(name, url)}](#{url})"
    end
  end

  defp link_label(name, url) do
    budget = max(@value_max - size(url) - @link_overhead, 1)
    name |> fit(budget) |> present()
  end

  defp field(name, value), do: %{"name" => name, "value" => present(value), "inline" => true}

  defp put_url(embed, nil), do: embed
  defp put_url(embed, url), do: Map.put(embed, "url", url)

  defp board_name(%{"name" => name}) when is_binary(name), do: name
  defp board_name(_board), do: nil

  defp board_url(%{"url" => url}), do: safe_url(url)
  defp board_url(_board), do: nil

  defp task_url(%{"url" => url}), do: safe_url(url)
  defp task_url(_task), do: nil

  defp column_name(%{"column" => %{"name" => name}}) when is_binary(name),
    do: fit(name, @value_max)

  defp column_name(_task), do: ""

  defp task_value(%{} = task, key) do
    case Map.get(task, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp task_value(_task, _key), do: nil

  # A URL is used as a link target only when it is an absolute http(s) URL
  # with nothing that could close a masked link or break out of it.
  defp safe_url(url) when is_binary(url) do
    if Regex.match?(~r{\Ahttps?://[^\s()<>\[\]]+\z}, url), do: url, else: nil
  end

  defp safe_url(_url), do: nil

  defp present(text, fallback \\ @placeholder) do
    if String.trim(text) == "", do: fallback, else: text
  end

  # Escapes `text` and fits it into `limit`, cutting on a grapheme boundary
  # and ending with an ellipsis when it does not fit.
  defp fit(text, limit) when is_binary(text) do
    escaped = escape(text)

    if size(escaped) <= limit, do: escaped, else: cut(text, limit - 1) <> "…"
  end

  defp fit(_text, _limit), do: ""

  # Escapes one grapheme at a time and stops before `budget`, so a cut never
  # splits a grapheme or leaves a lone escaping backslash.
  defp cut(text, budget) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, used} ->
      escaped = escape(grapheme)
      total = used + size(escaped)

      if total > budget, do: {:halt, {acc, used}}, else: {:cont, {[acc | escaped], total}}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp size(text), do: text |> String.codepoints() |> length()
end
