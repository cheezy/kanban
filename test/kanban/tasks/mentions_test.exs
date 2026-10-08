defmodule Kanban.Tasks.MentionsTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.Mentions

  doctest Mentions

  describe "parse/1" do
    test "returns no ids for content without tokens" do
      assert Mentions.parse("") == []
      assert Mentions.parse("no mentions here") == []
    end

    test "extracts one id" do
      assert Mentions.parse("ping @[Ada Lovelace](user:42) please") == [42]
    end

    test "extracts many ids in first-appearance order" do
      assert Mentions.parse("@[B](user:2) @[A](user:1) @[C](user:3)") == [2, 1, 3]
    end

    test "dedups repeated tokens for the same user" do
      assert Mentions.parse("@[A](user:1) @[Also A](user:1) @[B](user:2) @[A](user:1)") ==
               [1, 2]
    end

    test "ignores free-text @names" do
      assert Mentions.parse("@ada and @Ada Lovelace") == []
    end

    test "ignores tokens with a non-numeric, zero, signed or leading-zero id" do
      for content <- [
            "@[Ada](user:abc)",
            "@[Ada](user:)",
            "@[Ada](user:0)",
            "@[Ada](user:-1)",
            "@[Ada](user:007)",
            "@[Ada](user:1.5)",
            "@[Ada](user: 1)"
          ] do
        assert Mentions.parse(content) == [], content
      end
    end

    test "ignores an id too long to be a user id" do
      assert Mentions.parse("@[Ada](user:1234567890123456789)") == []
      assert Mentions.parse("@[Ada](user:123456789012345678)") == [123_456_789_012_345_678]
    end

    test "ignores tokens with unbalanced or missing brackets" do
      for content <- [
            "@[Ada(user:1)",
            "@Ada](user:1)",
            "@[Ada](user:1",
            "@[](user:1)",
            "[Ada](user:1)",
            "@(Ada)[user:1]"
          ] do
        assert Mentions.parse(content) == [], content
      end
    end

    test "accepts display names containing brackets or parentheses" do
      assert Mentions.parse("@[Ada [Ops] (she/her)](user:5)") == [5]
      assert Mentions.parse("@[Weird] name)](user:6)") == [6]
    end

    test "does not let a name span a line break or another token" do
      assert Mentions.parse("@[Ada\nLovelace](user:1)") == []
      assert Mentions.parse("@[Ada @[Bo](user:2)") == [2]

      assert Mentions.segments("@[Ada @[Bo](user:2)", %{2 => "Bo"}) ==
               [{:text, "@[Ada "}, {:mention, 2, "Bo"}]
    end

    test "does not let a malformed token swallow a later valid one" do
      assert Mentions.parse("@[A](user:x) then b](user:5)") == []

      assert Mentions.segments("@[A](user:x) then @[B](user:5)", %{5 => "Bo"}) ==
               [{:text, "@[A](user:x) then "}, {:mention, 5, "Bo"}]
    end

    test "ignores names longer than 640 code points" do
      assert Mentions.parse("@[#{String.duplicate("a", 641)}](user:1)") == []
      assert Mentions.parse("@[#{String.duplicate("a", 640)}](user:1)") == [1]
    end

    test "accepts a maximum-length name whose graphemes span several code points" do
      # 160 graphemes (the User.name maximum), each "e" plus a combining acute
      # accent: 320 code points.
      name = String.duplicate("e\u0301", 160)
      assert String.length(name) == 160
      assert Mentions.parse("@[#{name}](user:1)") == [1]
    end

    test "handles hundreds of tokens in one comment" do
      content = Enum.map_join(1..500, " ", &"@[U#{&1}](user:#{&1})")
      assert Mentions.parse(content) == Enum.to_list(1..500)
    end

    test "returns [] for non-strings and invalid UTF-8" do
      assert Mentions.parse(nil) == []
      assert Mentions.parse(123) == []
      assert Mentions.parse(<<"@[A](user:1) ", 0xFF>>) == []
    end
  end

  describe "resolve/2" do
    test "keeps only member ids, in order" do
      assert Mentions.resolve([5, 1, 9, 3], [3, 5, 7]) == [5, 3]
    end

    test "accepts a MapSet of member ids" do
      assert Mentions.resolve([5, 1, 3], MapSet.new([1, 3])) == [1, 3]
    end

    test "returns [] when nobody is a member" do
      assert Mentions.resolve([1, 2], []) == []
      assert Mentions.resolve([], [1, 2]) == []
    end

    test "caps the result at max_mentions/0" do
      max = Mentions.max_mentions()
      ids = Enum.to_list(1..(max + 5))
      assert Mentions.resolve(ids, ids) == Enum.to_list(1..max)
    end

    test "applies the cap after the membership filter" do
      max = Mentions.max_mentions()
      non_members = Enum.to_list(1001..(1000 + max))
      members = [1, 2]
      assert Mentions.resolve(non_members ++ members, members) == members
    end
  end

  describe "added/2" do
    test "returns ids in current that were not in previous" do
      assert Mentions.added([1, 2], [2, 3, 1, 4]) == [3, 4]
    end

    test "returns [] when nothing was added" do
      assert Mentions.added([1, 2], [2]) == []
      assert Mentions.added([], []) == []
    end

    test "returns every id when nothing was mentioned before" do
      assert Mentions.added([], [3, 1]) == [3, 1]
    end
  end

  describe "segments/2" do
    test "returns one text segment for content without tokens" do
      assert Mentions.segments("just text", %{}) == [{:text, "just text"}]
    end

    test "returns no segments for empty content" do
      assert Mentions.segments("", %{1 => "Ada"}) == []
    end

    test "turns a resolved token into a mention with the map's name, not the token's" do
      assert Mentions.segments("@[Old Name](user:1)", %{1 => "New Name"}) ==
               [{:mention, 1, "New Name"}]
    end

    test "leaves an unresolved token as text merged with its neighbours" do
      assert Mentions.segments("a @[X](user:2) b @[Y](user:1) c", %{1 => "Ada"}) ==
               [{:text, "a @[X](user:2) b "}, {:mention, 1, "Ada"}, {:text, " c"}]
    end

    test "renders adjacent and repeated mentions" do
      assert Mentions.segments("@[A](user:1)@[A](user:1)", %{1 => "Ada"}) ==
               [{:mention, 1, "Ada"}, {:mention, 1, "Ada"}]
    end

    test "carries surrounding markup verbatim and unescaped, for HEEx to escape" do
      content = "<script>alert(1)</script> @[<b>x</b>](user:1) & <img src=x>"

      assert Mentions.segments(content, %{1 => "Ada"}) == [
               {:text, "<script>alert(1)</script> "},
               {:mention, 1, "Ada"},
               {:text, " & <img src=x>"}
             ]
    end

    test "keeps line breaks in text" do
      assert Mentions.segments("line 1\n@[A](user:1)\nline 3", %{1 => "Ada"}) ==
               [{:text, "line 1\n"}, {:mention, 1, "Ada"}, {:text, "\nline 3"}]
    end

    test "preserves multibyte text around tokens" do
      assert Mentions.segments("héllo @[A](user:1) 日本", %{1 => "Ada"}) ==
               [{:text, "héllo "}, {:mention, 1, "Ada"}, {:text, " 日本"}]
    end

    test "returns [] for non-strings and invalid UTF-8" do
      assert Mentions.segments(nil, %{}) == []
      assert Mentions.segments(<<0xFF>>, %{}) == []
    end
  end

  describe "token_name/1" do
    defp parses_as_one_mention?(name),
      do: Mentions.parse("@[" <> Mentions.token_name(name) <> "](user:7)") == [7]

    test "leaves an ordinary name unchanged" do
      assert Mentions.token_name("Ada Lovelace") == "Ada Lovelace"
      assert Mentions.token_name("Zoë [QA] (ops)") == "Zoë [QA] (ops)"
    end

    test "replaces line breaks with a space" do
      assert Mentions.token_name("Ada\nLovelace") == "Ada Lovelace"
      assert Mentions.token_name("Ada\r\nLovelace") == "Ada Lovelace"
    end

    test "breaks up the sequences that would end or nest a token" do
      assert Mentions.token_name("a@[b") == "a@ [b"
      assert Mentions.token_name("a](user:9)b") == "a] (user:9)b"
    end

    test "trims surrounding whitespace and yields \"\" for a blank name" do
      assert Mentions.token_name("  Ada  ") == "Ada"
      assert Mentions.token_name(" \n ") == ""
    end

    test "cuts a long name to 640 code points" do
      name = "é" |> String.duplicate(700) |> Mentions.token_name()

      assert String.length(name) == 640
      assert parses_as_one_mention?(name)
    end

    test "always yields a name that parses as exactly one mention" do
      hostile = [
        "Ada",
        "a@[b](user:1)",
        "x](user:2)",
        "@@[[",
        "line\nbreak",
        "ends with ](user",
        "ends with @",
        "](",
        "a@b.example",
        String.duplicate("@[", 400)
      ]

      for name <- hostile, do: assert(parses_as_one_mention?(name), inspect(name))
    end
  end
end
