defmodule Kanban.Webhooks.DiscordFormatterTest do
  use ExUnit.Case, async: true

  alias Kanban.Webhooks.DiscordFormatter
  alias Kanban.Webhooks.Endpoint

  @board %{"id" => 1, "name" => "Road & map", "url" => "https://stride.test/boards/1"}
  @task_url "https://stride.test/boards/1/tasks/5/edit"

  defp envelope(event, task_attrs \\ %{}, board \\ @board) do
    task =
      Map.merge(
        %{
          "identifier" => "W12",
          "title" => "Ship it",
          "url" => @task_url,
          "column" => %{"id" => 3, "name" => "Doing"}
        },
        task_attrs
      )

    %{"event" => event, "board" => board, "task" => task}
  end

  defp ping(board \\ @board), do: %{"event" => "ping", "board" => board, "task" => nil}

  defp embed(%{"embeds" => [embed]}), do: embed

  defp field(message, name) do
    message |> embed() |> Map.fetch!("fields") |> Enum.find(&(&1["name"] == name))
  end

  defp field_value(message, name), do: field(message, name)["value"]

  defp all_text(message), do: Jason.encode!(message)

  defp size(text), do: text |> String.codepoints() |> length()

  # Discord's 6000 limit: title, description, field names and values (plus
  # footer and author, which the formatter never sets).
  defp embed_size(embed) do
    fields = Map.get(embed, "fields", [])

    texts =
      [embed["title"], embed["description"]] ++ Enum.flat_map(fields, &[&1["name"], &1["value"]])

    texts |> Enum.reject(&is_nil/1) |> Enum.map(&size/1) |> Enum.sum()
  end

  defp event_messages,
    do: Enum.map(Endpoint.event_types(), &DiscordFormatter.format(envelope(&1)))

  test "renders every event with identifier, title, event, column and links" do
    for event <- Endpoint.event_types() do
      message = event |> envelope() |> DiscordFormatter.format()
      embed = embed(message)

      assert message["content"] =~ "W12 Ship it was "
      assert embed["title"] == "W12 Ship it"
      assert embed["url"] == @task_url
      assert embed["description"] =~ ~r/^Task \*\*.+\*\*$/
      assert field_value(message, "Event") == DiscordFormatter.escape(event)
      assert field_value(message, "Column") == "Doing"
      assert field_value(message, "Board") == "[Road & map](https://stride.test/boards/1)"
    end
  end

  test "uses readable event labels" do
    message = "task.moved_to_review" |> envelope() |> DiscordFormatter.format()

    assert message["content"] == "W12 Ship it was moved to review"
    assert embed(message)["description"] == "Task **moved to review**"
    assert field_value(message, "Event") == "task\\.moved\\_to\\_review"
  end

  test "an unknown event falls back to the escaped raw event" do
    message = "task.archived" |> envelope() |> DiscordFormatter.format()

    assert message["content"] == "W12 Ship it was task\\.archived"
    assert embed(message)["description"] == "Task **task\\.archived**"
    assert field_value(message, "Event") == "task\\.archived"
  end

  test "a ping names the board and links to it" do
    message = DiscordFormatter.format(ping())
    embed = embed(message)

    assert message["content"] == "Stride test message for board Road & map"
    assert embed["title"] == "Stride test message"
    assert embed["url"] == "https://stride.test/boards/1"
    assert field_value(message, "Board") == "[Road & map](https://stride.test/boards/1)"
  end

  test "a ping for a board without a name or url still renders" do
    message = %{"id" => 1, "name" => nil, "url" => nil} |> ping() |> DiscordFormatter.format()

    assert message["content"] == "Stride test message for board —"
    refute message |> embed() |> Map.has_key?("url")
    assert field_value(message, "Board") == "—"

    assert (nil |> ping() |> DiscordFormatter.format())["content"] ==
             "Stride test message for board —"
  end

  test "every message sets allowed_mentions to an empty parse list" do
    for message <- [DiscordFormatter.format(ping()) | event_messages()] do
      assert message["allowed_mentions"] == %{"parse" => []}
      assert message |> Map.keys() |> Enum.sort() == ["allowed_mentions", "content", "embeds"]
      refute Map.has_key?(message, "username")
      refute Map.has_key?(message, "avatar_url")
      assert is_binary(Jason.encode!(message))
    end
  end

  test "titles and names with @everyone, @here, <@123>, markdown and [text](url) are escaped" do
    hostile =
      "@everyone @here <@123> <@&9> <#5> **b** _i_ ~~s~~ `c` ||spoiler|| " <>
        "[click](https://evil.test) https://evil.test"

    message =
      "task.created"
      |> envelope(
        %{
          "title" => hostile,
          "identifier" => "W<1>",
          "column" => %{"id" => 3, "name" => "1. > # Backlog"}
        },
        %{@board | "name" => "]](https://evil.test) @here"}
      )
      |> DiscordFormatter.format()

    texts = [
      message["content"],
      embed(message)["title"] | Enum.map(embed(message)["fields"], & &1["value"])
    ]

    for text <- texts do
      refute text =~ ~r/(?<!\\)@(everyone|here)/
      refute text =~ ~r/(?<!\\)<[@#]/
      refute text =~ ~r/(?<!\\)\*\*b/
      refute text =~ ~r/(?<!\\)\]\(https:\/\/evil/
      refute text =~ ~r/(?<!\\)https:\/\/evil/
      refute text =~ ~r/(?<!\\)\|\|/
    end

    assert embed(message)["title"] =~
             "W\\<1\\> \\@everyone \\@here \\<\\@123\\> \\<\\@&9\\> \\<\\#5\\>"

    assert embed(message)["title"] =~
             "\\*\\*b\\*\\* \\_i\\_ \\~\\~s\\~\\~ \\`c\\` \\|\\|spoiler\\|\\|"

    assert embed(message)["title"] =~ "\\[click\\]\\(https\\://evil\\.test\\)"
    assert field_value(message, "Column") == "1\\. \\> \\# Backlog"

    assert field_value(message, "Board") ==
             "[\\]\\]\\(https\\://evil\\.test\\) \\@here](https://stride.test/boards/1)"

    assert embed(message)["url"] == @task_url
  end

  test "line breaks in board text collapse to spaces" do
    message =
      "task.created"
      |> envelope(%{"title" => "one\r\n# two\n- three", "column" => %{"id" => 3, "name" => "\n"}})
      |> DiscordFormatter.format()

    assert embed(message)["title"] == "W12 one \\# two \\- three"
    assert field_value(message, "Column") == "—"
  end

  test "only absolute http(s) Stride URLs become link targets" do
    message =
      "task.updated"
      |> envelope(%{"url" => "javascript:alert(1)"}, %{
        @board
        | "url" => "https://x.test/a) [b](c"
      })
      |> DiscordFormatter.format()

    refute message |> embed() |> Map.has_key?("url")
    assert field_value(message, "Board") == "Road & map"
  end

  test "escape/1 handles nil, backslashes, markdown, mentions and line breaks" do
    assert DiscordFormatter.escape(nil) == ""
    assert DiscordFormatter.escape("\\") == "\\\\"
    assert DiscordFormatter.escape("a*b") == "a\\*b"
    assert DiscordFormatter.escape("@everyone") == "\\@everyone"
    assert DiscordFormatter.escape("a\r\nb\nc") == "a b c"
    assert DiscordFormatter.escape("Road & map") == "Road & map"
  end

  test "a 5000-character title is shortened within the embed title limit and the 6000-character total" do
    long = String.duplicate("x", 5000)

    message =
      "task.updated"
      |> envelope(%{"title" => long, "column" => %{"id" => 3, "name" => long}}, %{
        @board
        | "name" => long
      })
      |> DiscordFormatter.format()

    embed = embed(message)

    assert size(embed["title"]) == 256
    assert String.ends_with?(embed["title"], "…")
    assert size(message["content"]) <= 2000
    assert Enum.all?(embed["fields"], &(size(&1["value"]) <= 1024))
    assert size(field_value(message, "Board")) == 1024
    assert size(embed["description"]) <= 4096
    assert embed_size(embed) <= 6000
  end

  test "cutting escaped text never leaves a lone escaping backslash" do
    message =
      "task.updated"
      |> envelope(%{"title" => String.duplicate("*", 500)})
      |> DiscordFormatter.format()

    [before_ellipsis] = String.split(embed(message)["title"], "…", trim: true)
    [_, stars] = String.split(before_ellipsis, " ", parts: 2)

    assert size(embed(message)["title"]) <= 256
    assert rem(String.length(stars), 2) == 0
    assert stars == String.duplicate("\\*", div(String.length(stars), 2))
  end

  test "a title exactly at the limit is kept whole and one character over is shortened" do
    at_limit = String.duplicate("y", 256 - 4)

    kept = "task.created" |> envelope(%{"title" => at_limit}) |> DiscordFormatter.format()
    cut = "task.created" |> envelope(%{"title" => at_limit <> "y"}) |> DiscordFormatter.format()

    assert embed(kept)["title"] == "W12 " <> at_limit
    assert size(embed(cut)["title"]) == 256
    assert String.ends_with?(embed(cut)["title"], "y…")
  end

  test "emoji are counted by code point and never split" do
    family = "👨‍👩‍👧‍👦"

    message =
      "task.created"
      |> envelope(%{"title" => String.duplicate(family, 300)})
      |> DiscordFormatter.format()

    "W12 " <> rest = embed(message)["title"]

    assert size(embed(message)["title"]) <= 256
    assert rest |> String.graphemes() |> Enum.all?(&(&1 in [family, "…"]))
  end

  test "nil title, column and board name do not raise" do
    message =
      "task.moved"
      |> envelope(%{"title" => nil, "column" => nil}, %{@board | "name" => nil})
      |> DiscordFormatter.format()

    assert embed(message)["title"] == "W12"
    assert field_value(message, "Column") == "—"
    assert field_value(message, "Board") == "[—](https://stride.test/boards/1)"
    assert Enum.all?(embed(message)["fields"], &(&1["value"] != ""))

    untitled =
      "task.deleted"
      |> envelope(%{"title" => nil, "identifier" => nil})
      |> DiscordFormatter.format()

    assert embed(untitled)["title"] == "Untitled task"
    assert untitled["content"] == "Untitled task was deleted"

    bare = DiscordFormatter.format(%{"event" => "task.deleted", "board" => nil, "task" => nil})
    assert embed(bare)["title"] == "Untitled task"
    assert field_value(bare, "Board") == "—"
    assert field_value(bare, "Column") == "—"
    refute bare |> embed() |> Map.has_key?("url")

    no_event = DiscordFormatter.format(%{"event" => nil, "board" => @board, "task" => nil})
    assert field_value(no_event, "Event") == "—"
    assert is_binary(all_text(no_event))
  end
end
