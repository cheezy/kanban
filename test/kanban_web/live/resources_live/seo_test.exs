defmodule KanbanWeb.ResourcesLive.SeoTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ResourcesLive.Seo

  describe "resources_description/0" do
    test "is between 70 and 160 characters in English" do
      assert String.length(Seo.resources_description()) in 70..160
    end

    test "follows the current locale" do
      french = Gettext.with_locale(KanbanWeb.Gettext, "fr", &Seo.resources_description/0)

      assert String.starts_with?(french, "Guides pas à pas pour Stride")
      refute french == Seo.resources_description()
    end
  end

  describe "how_to_meta_description/1" do
    test "uses a short description unchanged, trimmed" do
      assert Seo.how_to_meta_description(%{description: "  Create your first board.  "}) ==
               "Create your first board."
    end

    test "keeps a description of exactly 160 characters" do
      description = String.duplicate("a", 160)
      assert Seo.how_to_meta_description(%{description: description}) == description
    end

    test "shortens a long description on a word boundary to at most 160 characters" do
      # 159 characters of "words words …" end mid-word, in "wor".
      description = String.duplicate("words ", 40) <> "end."
      shortened = Seo.how_to_meta_description(%{description: description})

      assert String.length(shortened) <= 160
      assert String.ends_with?(shortened, "words…")
      assert String.starts_with?(description, String.trim_trailing(shortened, "…"))
    end

    test "drops trailing punctuation before the ellipsis" do
      description = String.duplicate("a", 150) <> " one, " <> String.duplicate("b", 20)
      assert Seo.how_to_meta_description(%{description: description}) =~ ~r/one…$/
    end

    test "drops connecting words left dangling at the cut" do
      description = String.duplicate("a", 140) <> " glance, and, on the boards that matter most"
      assert Seo.how_to_meta_description(%{description: description}) =~ ~r/a glance…$/
    end

    test "no shortened how-to description ends on a connecting word" do
      for how_to <- KanbanWeb.ResourcesLive.HowToData.all_how_tos(),
          String.length(how_to.description) > 160 do
        shortened = Seo.how_to_meta_description(how_to)

        refute shortened =~ ~r/(?:\b(?:and|or|the|a|an|to|of|in|on|for|with)|[,;:])…$/iu,
               "#{how_to.id} ends on a dangling word: #{shortened}"
      end
    end

    test "cuts a single unbroken word at 159 characters plus the ellipsis" do
      shortened = Seo.how_to_meta_description(%{description: String.duplicate("x", 200)})
      assert shortened == String.duplicate("x", 159) <> "…"
    end

    test "falls back to the resources description when there is none" do
      for how_to <- [%{description: ""}, %{description: "   "}, %{description: nil}, %{}] do
        assert Seo.how_to_meta_description(how_to) == Seo.resources_description()
      end
    end
  end
end
