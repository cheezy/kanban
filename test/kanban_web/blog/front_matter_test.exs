defmodule KanbanWeb.Blog.FrontMatterTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.Blog.FrontMatter

  @path "priv/blog/posts/example.md"

  defp post(lines), do: "---\n" <> Enum.join(lines, "\n") <> "\n---\n\nBody text.\n"

  @valid [
    "date: '2026-03-18T13:47:00-04:00'",
    "draft: false",
    "title: 'The future of software engineering: My Thoughts - Part 1'",
    ~s(tags: ["AI", "Continuous Delivery"]),
    "author: cheezy",
    "slug: 'tw-retreat-response'",
    ~s(description: "A short description.")
  ]

  defp raises(lines, message) do
    error = assert_raise ArgumentError, fn -> lines |> post() |> FrontMatter.parse!(@path) end
    assert error.message =~ @path
    assert error.message =~ message
  end

  describe "keys/0 and required_keys/0" do
    test "list the seven accepted keys and the five required ones, sorted" do
      assert FrontMatter.keys() == ~w(author date description draft slug tags title)
      assert FrontMatter.required_keys() == ~w(author date description slug title)
    end

    test "every listed key parses and a key outside the list raises" do
      {fields, _body} = @valid |> post() |> FrontMatter.parse!(@path)

      assert fields |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
               FrontMatter.keys()

      raises(@valid ++ ["summary: 'x'"], ~s(unknown front matter key "summary"))
    end
  end

  describe "parse!/2" do
    test "parses quoted strings, string lists, booleans and a bare author" do
      {fields, body} = @valid |> post() |> FrontMatter.parse!(@path)

      assert fields.title == "The future of software engineering: My Thoughts - Part 1"
      assert fields.tags == ["AI", "Continuous Delivery"]
      assert fields.draft == false
      assert fields.author == "cheezy"
      assert fields.slug == "tw-retreat-response"
      assert fields.description == "A short description."
      assert body == "\nBody text.\n"
    end

    test "parses dates with an offset to the same instant in UTC" do
      {fields, _body} = @valid |> post() |> FrontMatter.parse!(@path)

      assert fields.date == ~U[2026-03-18 17:47:00Z]
      assert fields.date.time_zone == "Etc/UTC"
    end

    test "turns a doubled single quote into one and accepts true, an empty list and a quoted author" do
      lines =
        @valid
        |> List.replace_at(1, "draft: true")
        |> List.replace_at(2, "title: 'It''s here'")
        |> List.replace_at(3, "tags: []")
        |> List.replace_at(4, ~s(author: "cheezy"))

      {fields, _body} = lines |> post() |> FrontMatter.parse!(@path)

      assert fields.title == "It's here"
      assert fields.draft == true
      assert fields.tags == []
      assert fields.author == "cheezy"
    end

    test "defaults draft to false and tags to an empty list, and skips blank lines" do
      lines = @valid |> List.delete_at(3) |> List.delete_at(1) |> List.insert_at(1, "")

      {fields, _body} = lines |> post() |> FrontMatter.parse!(@path)

      assert fields.draft == false
      assert fields.tags == []
    end

    test "raises on an unknown key" do
      raises(@valid ++ ["layout: 'post'"], ~s(unknown front matter key "layout"))
    end

    test "raises on a missing title or date" do
      raises(List.delete_at(@valid, 2), ~s(missing front matter key "title"))
      raises(List.delete_at(@valid, 0), ~s(missing front matter key "date"))
    end

    test "raises on a malformed line, naming its line number" do
      raises(
        List.insert_at(@valid, 1, "this is not a key value line"),
        "malformed front matter line 3"
      )
    end

    test "raises on a duplicate key" do
      raises(@valid ++ ["slug: 'again'"], ~s(duplicate front matter key "slug"))
    end

    test "raises on malformed values" do
      raises(
        List.replace_at(@valid, 2, "title: 'unterminated"),
        ~s(malformed value for front matter key "title")
      )

      raises(
        List.replace_at(@valid, 2, ~s(title: "a \\" b")),
        ~s(malformed value for front matter key "title")
      )

      raises(
        List.replace_at(@valid, 3, ~s(tags: ["AI", bare])),
        ~s(malformed value for front matter key "tags")
      )

      raises(
        List.replace_at(@valid, 4, "author: two words"),
        ~s(malformed value for front matter key "author")
      )
    end

    test "raises on a value of the wrong type" do
      raises(
        List.replace_at(@valid, 1, "draft: 'false'"),
        ~s(wrong type of value for front matter key "draft")
      )

      raises(
        List.replace_at(@valid, 3, ~s(tags: "AI")),
        ~s(wrong type of value for front matter key "tags")
      )

      raises(
        List.replace_at(@valid, 2, "title: bare"),
        ~s(wrong type of value for front matter key "title")
      )

      raises(
        List.replace_at(@valid, 0, "date: 2026"),
        ~s(wrong type of value for front matter key "date")
      )
    end

    test "raises on an empty or blank title, slug or description" do
      raises(List.replace_at(@valid, 2, "title: ''"), ~s(empty front matter key "title"))
      raises(List.replace_at(@valid, 2, ~s(title: "   ")), ~s(empty front matter key "title"))

      raises(
        List.replace_at(@valid, 6, ~s(description: "")),
        ~s(empty front matter key "description")
      )

      raises(List.replace_at(@valid, 5, "slug: ''"), ~s(empty front matter key "slug"))
    end

    test "raises on a slug that is not URL-safe" do
      for slug <- ["two words", "a/b", "../x", "Upper", "-lead", "trail-", "a--b", "a_b", "é"] do
        raises(
          List.replace_at(@valid, 5, "slug: '#{slug}'"),
          ~s(front matter key "slug" must be lower-case letters, digits and single hyphens)
        )
      end
    end

    test "accepts a slug of lower-case letters and digits joined by hyphens" do
      for slug <- ["a", "how-much", "part-2-of-3", "2026"] do
        {fields, _body} =
          @valid |> List.replace_at(5, "slug: '#{slug}'") |> post() |> FrontMatter.parse!(@path)

        assert fields.slug == slug
      end
    end

    test "raises on a date that is not ISO 8601 with an offset" do
      raises(List.replace_at(@valid, 0, "date: 'yesterday'"), ~s(invalid front matter key "date"))
    end

    test "raises when there is no front matter block" do
      error = assert_raise ArgumentError, fn -> FrontMatter.parse!("Just a body.\n", @path) end
      assert error.message =~ "#{@path}: no front matter block"
    end
  end
end
