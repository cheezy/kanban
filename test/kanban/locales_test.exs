defmodule Kanban.LocalesTest do
  use ExUnit.Case, async: true

  alias Kanban.Locales

  describe "resolve/1" do
    test "an exact translated locale is itself, whatever its case" do
      for locale <- ~w(en de fr es pt ja zh) do
        assert Locales.resolve(locale) == locale
        assert locale |> String.upcase() |> Locales.resolve() == locale
      end
    end

    test "a region or script tag falls back to its base language" do
      table = [
        {"de-AT", "de"},
        {"de-CH", "de"},
        {"pt-BR", "pt"},
        {"pt_BR", "pt"},
        {"PT-br", "pt"},
        {"zh-Hant-TW", "zh"},
        {"zh_Hans_CN", "zh"},
        {"ja-JP", "ja"},
        {"fr-CA", "fr"},
        {"es-419", "es"},
        {"en-GB", "en"},
        {" de-AT ", "de"}
      ]

      for {tag, expected} <- table do
        assert Locales.resolve(tag) == expected, "#{inspect(tag)} should be #{expected}"
      end
    end

    test "a language Stride is not translated into, or no tag, is English" do
      for tag <- ["ko", "ko-KR", "it", "nl-NL", "xx", "", "-", nil, 42] do
        assert Locales.resolve(tag) == "en", "#{inspect(tag)} should be en"
      end
    end

    test "the base language must match a whole subtag, not a prefix" do
      # "dex" is not German, and "zhx-TW" is not Chinese.
      assert Locales.resolve("dex") == "en"
      assert Locales.resolve("zhx-TW") == "en"
    end

    test "every resolved locale is one KanbanWeb.Gettext knows" do
      known = Gettext.known_locales(KanbanWeb.Gettext)

      for tag <- ["de-AT", "ko", "pt-BR", "zh-Hant-TW", nil] do
        assert Locales.resolve(tag) in known
      end

      assert Locales.default() == "en"
    end
  end
end
