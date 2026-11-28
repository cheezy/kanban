defmodule Kanban.BlogDocsTest do
  @moduledoc """
  Keeps the front matter table in `docs/blog.md` in step with
  `KanbanWeb.Blog.FrontMatter` (W2952), so a key added to or removed from
  the parser fails here until the guide says so.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.Blog.FrontMatter

  @doc_path "docs/blog.md"

  setup_all do
    %{rows: @doc_path |> File.read!() |> key_rows()}
  end

  # Rows of the key table look like "| `title` | Yes | ... |".
  defp key_rows(doc) do
    for [key, required] <-
          Regex.scan(~r/^\| `([a-z_]+)` \| (Yes|No)\b/m, doc, capture: :all_but_first),
        do: {key, required == "Yes"}
  end

  test "the key table lists exactly the keys FrontMatter accepts", %{rows: rows} do
    assert rows |> Enum.map(&elem(&1, 0)) |> Enum.sort() == FrontMatter.keys()
  end

  test "the key table marks exactly the required keys as required", %{rows: rows} do
    required = for {key, true} <- rows, do: key
    assert Enum.sort(required) == FrontMatter.required_keys()
  end

  test "the example front matter block parses" do
    [example] =
      Regex.run(~r/^```markdown\n(---\n.*?\n---\n.*?)```$/ms, File.read!(@doc_path),
        capture: :all_but_first
      )

    {fields, _body} = FrontMatter.parse!(example, @doc_path)

    assert fields |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
             FrontMatter.keys()
  end
end
