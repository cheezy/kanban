defmodule Kanban.Webhooks.SlackFormatterTest do
  use ExUnit.Case, async: true

  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.SlackFormatter

  @board %{"id" => 1, "name" => "Road & map", "url" => "https://stride.test/boards/1"}

  defp envelope(event, task_attrs \\ %{}) do
    task =
      Map.merge(
        %{
          "identifier" => "W12",
          "title" => "Ship it",
          "url" => "https://stride.test/boards/1/tasks/5/edit",
          "column" => %{"id" => 3, "name" => "Doing"}
        },
        task_attrs
      )

    %{"event" => event, "board" => @board, "task" => task}
  end

  defp all_text(%{"text" => text, "blocks" => blocks}) do
    [text | Enum.map(blocks, &Jason.encode!/1)] |> Enum.join("\n")
  end

  test "renders every event with identifier, title, event, column and links" do
    for event <- Endpoint.event_types() do
      message = event |> envelope() |> SlackFormatter.format()
      text = all_text(message)

      assert message["text"] =~ "W12 Ship it was "
      assert text =~ "<https://stride.test/boards/1/tasks/5/edit|Ship it>"
      assert text =~ "<https://stride.test/boards/1|Road &amp; map>"
      assert text =~ "Column: Doing"
      assert text =~ event
    end
  end

  test "uses readable event labels" do
    assert ("task.moved_to_review" |> envelope() |> SlackFormatter.format())["text"] =~
             "was moved to review"

    assert ("task.created" |> envelope() |> SlackFormatter.format())["text"] =~ "was created"
  end

  test "a ping names the board and links to it" do
    message = SlackFormatter.format(%{"event" => "ping", "board" => @board, "task" => nil})

    assert message["text"] == "Stride test message for board Road &amp; map"
    assert all_text(message) =~ "<https://stride.test/boards/1|open the board>"
  end

  test "escapes Slack control characters in titles, names and identifiers" do
    message =
      "task.created"
      |> envelope(%{
        "title" => "<!channel> & <https://evil.test|click>",
        "identifier" => "W<1>",
        "column" => %{"id" => 3, "name" => "A&B"}
      })
      |> SlackFormatter.format()

    text = all_text(message)

    refute text =~ "<!channel>"
    refute text =~ "<https://evil.test"
    assert text =~ "&lt;!channel&gt; &amp; &lt;https://evil.test|click&gt;"
    assert text =~ "W&lt;1&gt;"
    assert text =~ "Column: A&amp;B"
  end

  test "escape/1 handles nil and escapes & first" do
    assert SlackFormatter.escape(nil) == ""
    assert SlackFormatter.escape("&lt;") == "&amp;lt;"
  end

  test "long titles are cut to 200 characters" do
    message =
      "task.updated"
      |> envelope(%{"title" => String.duplicate("x", 500)})
      |> SlackFormatter.format()

    [_, title] = Regex.run(~r/W12 (x+…) was/u, message["text"])
    assert String.length(title) == 200
  end

  test "a task without a column renders an empty column" do
    message = "task.deleted" |> envelope(%{"column" => nil}) |> SlackFormatter.format()
    assert all_text(message) =~ "Column: "
  end
end
