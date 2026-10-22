defmodule KanbanWeb.SentencesTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.Sentences

  defp in_locale(locale, fun), do: Gettext.with_locale(KanbanWeb.Gettext, locale, fun)

  test "Chinese and Japanese sentences are joined with no space" do
    for locale <- ~w(ja zh) do
      assert in_locale(locale, fn -> Sentences.join(["一。", "二。"]) end) == "一。二。"
      assert in_locale(locale, &Sentences.separator/0) == ""
    end
  end

  test "every other supported locale joins sentences with one space" do
    for locale <- Gettext.known_locales(KanbanWeb.Gettext) -- ~w(ja zh) do
      assert in_locale(locale, fn -> Sentences.join(["One.", "Two."]) end) == "One. Two."
      assert in_locale(locale, &Sentences.separator/0) == " "
    end
  end

  test "one sentence or none is returned as is" do
    assert Sentences.join(["Only."]) == "Only."
    assert Sentences.join([]) == ""
  end
end
