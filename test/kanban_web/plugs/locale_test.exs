defmodule KanbanWeb.Plugs.LocaleTest do
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.Plugs.Locale

  defp call(conn), do: Locale.call(conn, "en")

  setup %{conn: conn} do
    %{conn: init_test_session(conn, %{})}
  end

  test "a supported ?locale= is used and kept in the session", %{conn: conn} do
    conn = %{conn | query_string: "locale=de"} |> call()

    assert get_session(conn, :locale) == "de"
    assert Gettext.get_locale(KanbanWeb.Gettext) == "de"
  end

  test "?locale= replaces the session's language", %{conn: conn} do
    conn = %{put_session(conn, :locale, "fr") | query_string: "locale=ja"} |> call()

    assert get_session(conn, :locale) == "ja"
  end

  test "an unsupported ?locale= is ignored and the session's language stays",
       %{conn: conn} do
    for value <- ["xx", "", "de&x", "../en"] do
      query = URI.encode_query(locale: value)
      conn = %{put_session(conn, :locale, "fr") | query_string: query} |> call()

      assert get_session(conn, :locale) == "fr"
      assert Gettext.get_locale(KanbanWeb.Gettext) == "fr"
    end
  end

  test "with no ?locale= the session's language is used", %{conn: conn} do
    conn = conn |> put_session(:locale, "pt") |> call()

    assert get_session(conn, :locale) == "pt"
    assert Gettext.get_locale(KanbanWeb.Gettext) == "pt"
  end

  test "a public page opened with ?locale= renders in that language", %{conn: conn} do
    conn = get(conn, ~p"/pricing?locale=de")

    assert html_response(conn, 200) =~ "Preise"
    assert get_session(conn, :locale) == "de"
  end
end
