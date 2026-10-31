defmodule KanbanWeb.PageControllerHitMeTest do
  @moduledoc """
  Covers the public /HitMe page (W2534), the page the printed handout's URL and
  QR code point to. Its hero mirrors the front of the flyer, so these tests pin
  the flyer's copy, the chip row, the sticker and the email button.
  """
  use KanbanWeb.ConnCase, async: true

  alias KanbanWeb.PageHTML

  @template "lib/kanban_web/controllers/page_html/hit_me.html.heex"

  defp main(body), do: body |> LazyHTML.from_document() |> LazyHTML.query("main")

  defp text_of(html, selector) do
    html |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  describe "GET /HitMe" do
    test "returns 200 and renders under the marketing layout", %{conn: conn} do
      doc = conn |> get(~p"/HitMe") |> html_response(200) |> LazyHTML.from_document()

      # The default root layout also wraps its nav in .stride-marketing, but only
      # the marketing root layout puts the page body inside that wrapper.
      assert doc |> LazyHTML.query(".stride-marketing main #hitme-hero") |> Enum.count() == 1
    end

    test "renders the kicker, the three heading lines and the half-day promise", %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert text_of(main, "#hitme-kicker") == "Stride with us"

      lines =
        main
        |> LazyHTML.query("#hitme-heading span")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert lines == ["Humans decide.", "Agents build.", "Everyone ships."]

      assert main |> LazyHTML.query("#hitme-heading-accent.hitme-accent") |> LazyHTML.text() =~
               "Everyone ships."

      assert text_of(main, "#hitme-lead") ==
               "In half a day: your backlog and agents set up, part of your proof of concept delivered, and your team is ready."
    end

    test "renders the four workflow chips with the flyer's captions", %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      chips =
        main
        |> LazyHTML.query("#hitme-chips .hitme-chip")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      captions =
        main
        |> LazyHTML.query("#hitme-chips .hitme-chip-caption")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert chips == ["Ready", "Doing", "Review", "Done"]
      assert captions == ["you", "agent", "you", "together"]

      # Only DONE is the filled chip, as printed.
      assert main |> LazyHTML.query("#hitme-chips .hitme-chip-done") |> LazyHTML.text() =~ "Done"
      assert main |> LazyHTML.query("#hitme-chips .hitme-chip-done") |> Enum.count() == 1
    end

    test "renders the address line with Stride as the accent", %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert text_of(main, "#hitme-address") == "StrideLikeABoss.com/HitMe"
      assert text_of(main, "#hitme-address .hitme-accent") == "Stride"
    end

    test "renders the sticker with its real size and translated alt text", %{conn: conn} do
      [img] =
        conn
        |> get(~p"/HitMe")
        |> html_response(200)
        |> main()
        |> LazyHTML.query("#hitme-sticker")
        |> Enum.to_list()

      assert LazyHTML.attribute(img, "src") == ["/images/marketing/hitme-sticker.png"]
      assert LazyHTML.attribute(img, "width") == ["504"]
      assert LazyHTML.attribute(img, "height") == ["504"]
      assert LazyHTML.attribute(img, "alt") == ["Stride sticker: Level Boss"]
    end

    test "the email button is a mailto for enterprise@letstango.ca with an encoded subject",
         %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      [href] = main |> LazyHTML.query("#hitme-email-button") |> LazyHTML.attribute("href")

      assert href ==
               "mailto:enterprise@letstango.ca?subject=Stride%20half-day%20proof-of-concept%20session"

      assert text_of(main, "#hitme-email-button") == "Email us to book a session"

      # The address is visible as text too, for a visitor without a mail client.
      assert text_of(main, "#hitme-email-address") == "enterprise@letstango.ca"
    end

    test "the page title names the half-day sessions", %{conn: conn} do
      body = conn |> get(~p"/HitMe") |> html_response(200)

      assert body |> LazyHTML.from_document() |> LazyHTML.query("title") |> LazyHTML.text() =~
               "Half-day AI proof-of-concept sessions"
    end

    test "renders for a signed-out visitor and for a signed-in user", %{conn: conn} do
      signed_out = conn |> get(~p"/HitMe") |> html_response(200)
      assert signed_out =~ ~s(id="hitme-hero")

      %{conn: signed_in_conn, user: user} = register_and_log_in_user(%{conn: build_conn()})
      signed_in = signed_in_conn |> get(~p"/HitMe") |> html_response(200)

      assert signed_in =~ ~s(id="hitme-hero")
      # The page itself shows nothing from the visitor's account.
      refute signed_in |> main() |> LazyHTML.to_html() =~ user.email
    end

    test "with the de locale renders the translated hero", %{conn: conn} do
      main =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "de"})
        |> get(~p"/HitMe")
        |> html_response(200)
        |> main()

      assert text_of(main, "#hitme-heading-accent") == "Alle liefern."
      refute LazyHTML.text(main) =~ "Everyone ships."

      [href] = main |> LazyHTML.query("#hitme-email-button") |> LazyHTML.attribute("href")
      assert href =~ ~r/^mailto:enterprise@letstango\.ca\?subject=[A-Za-z0-9%\-._~]+$/
      refute href =~ "proof-of-concept%20session"
    end

    test "with an unsupported locale falls back to the English copy", %{conn: conn} do
      main =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "xx"})
        |> get(~p"/HitMe")
        |> html_response(200)
        |> main()

      assert text_of(main, "#hitme-heading-accent") == "Everyone ships."
    end

    test "the template never passes gettext copy through raw/1" do
      refute File.read!(@template) =~ "raw("
    end
  end

  describe "the /HitMe layout rules in app.css" do
    # A browser check covers how these render; these pin the rules that keep the
    # tilted sticker and long translated lines from overflowing the card.
    setup do
      %{css: File.read!("assets/css/app.css")}
    end

    defp rule(css, selector) do
      [_, body] =
        Regex.run(~r/#{Regex.escape(selector)}\s*\{([^}]*)\}/, css) ||
          flunk("no #{selector} rule in app.css")

      body
    end

    test "both theme blocks define every --hitme-* token with the same value", %{css: css} do
      light = rule(css, ".stride-marketing,\n.stride-screen")

      dark =
        rule(
          css,
          ":where([data-theme=\"dark\"]) .stride-marketing,\n:where([data-theme=\"dark\"]) .stride-screen"
        )

      for token <- ~w(navy cyan yellow lead caption white on-cyan) do
        [_, value] = Regex.run(~r/--hitme-#{token}:\s*(#[0-9a-f]{6});/, light)
        assert dark =~ "--hitme-#{token}: #{value};", "dark block is missing --hitme-#{token}"
      end
    end

    test "the card clips the tilted sticker so the page never scrolls sideways", %{css: css} do
      assert rule(css, ".stride-marketing .hitme-card") =~ "overflow: hidden"
    end

    test "a long translated heading or address wraps inside the card", %{css: css} do
      assert rule(css, ".stride-marketing .hitme-heading") =~ "overflow-wrap: anywhere"
      assert rule(css, ".stride-marketing .hitme-address") =~ "overflow-wrap: anywhere"
    end

    test "on narrow screens the sticker is capped below the card's width", %{css: css} do
      sticker = rule(css, ".stride-marketing .hitme-sticker")

      assert sticker =~ "width: 220px"
      assert sticker =~ "max-width: 70%"
    end
  end

  describe "PageHTML.hit_me_mailto/1" do
    test "percent-encodes spaces as %20, not +" do
      assert PageHTML.hit_me_mailto("Book a session") ==
               "mailto:enterprise@letstango.ca?subject=Book%20a%20session"
    end

    test "encodes &, ? and = so a subject cannot add cc, bcc or body fields" do
      href = PageHTML.hit_me_mailto("Hi & bye?cc=attacker@example.test&body=x")

      assert href ==
               "mailto:enterprise@letstango.ca?subject=Hi%20%26%20bye%3Fcc%3Dattacker%40example.test%26body%3Dx"

      [_, query] = String.split(href, "?", parts: 2)
      assert query |> URI.decode_query() |> Map.keys() == ["subject"]
    end

    test "encodes non-ASCII characters as UTF-8 percent escapes" do
      assert PageHTML.hit_me_mailto("Sitzung für Teams") ==
               "mailto:enterprise@letstango.ca?subject=Sitzung%20f%C3%BCr%20Teams"
    end

    test "an empty subject still yields a valid mailto" do
      assert PageHTML.hit_me_mailto("") == "mailto:enterprise@letstango.ca?subject="
    end

    test "with no argument uses the translated booking subject" do
      assert PageHTML.hit_me_mailto() ==
               "mailto:enterprise@letstango.ca?subject=Stride%20half-day%20proof-of-concept%20session"
    end

    test "hit_me_address/0 is the address the button mails" do
      assert PageHTML.hit_me_address() == "enterprise@letstango.ca"
    end
  end
end
