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

    test "the hero card does not repeat the page's own address", %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert main |> LazyHTML.query("#hitme-address") |> Enum.count() == 0
      refute text_of(main, "#hitme-hero") =~ "LikeABoss.com/HitMe"
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

      [href] = main |> LazyHTML.query("#hitme-top-button") |> LazyHTML.attribute("href")

      assert href ==
               "mailto:enterprise@letstango.ca?subject=Stride%20half-day%20proof-of-concept%20session"

      assert text_of(main, "#hitme-top-button") == "Email us to book a session"

      # The address is visible as text too, for a visitor without a mail client.
      assert text_of(main, "#hitme-top-email") == "enterprise@letstango.ca"
    end

    test "the hero card has no email button or address of its own", %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert main |> LazyHTML.query("#hitme-hero a") |> Enum.count() == 0
      refute text_of(main, "#hitme-hero") =~ "enterprise@letstango.ca"
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

      [href] = main |> LazyHTML.query("#hitme-top-button") |> LazyHTML.attribute("href")
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

  describe "GET /HitMe below the hero (W2535)" do
    defp texts(html, selector) do
      html |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    defp main_in(conn, locale) do
      conn
      |> Plug.Test.init_test_session(%{"locale" => locale})
      |> get(~p"/HitMe")
      |> html_response(200)
      |> main()
    end

    test "renders 'desire' and 'knowledge' as highlighted words in the back heading",
         %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      # Exact text pins that the highlights add no whitespace around them.
      assert text_of(main, "#hitme-back-heading") == "Start with desire, leave with knowledge"
      assert texts(main, "#hitme-back-heading .hitme-accent") == ["desire", "knowledge"]
    end

    test "lists the five how-it-works steps in order, ending with Everybody celebrates",
         %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert texts(main, "#hitme-steps .hitme-step-number") == ~w(01 02 03 04 05)

      assert texts(main, "#hitme-steps .hitme-step-text") == [
               "You ideate with an agent to create the Backlog.",
               "An agent claims it and builds it.",
               "Your tests run before it reaches Review.",
               "A person approves it into Done.",
               "Everybody celebrates."
             ]

      assert texts(main, "#hitme-steps .hitme-step-strong") == [
               "You ideate with an agent",
               "An agent claims it",
               "Your tests run",
               "A person approves it",
               "Everybody celebrates."
             ]

      # The visible numbers are the only numbering a screen reader gets once
      # list-style is none, so they must not be hidden from it.
      assert main |> LazyHTML.query("#hitme-steps [aria-hidden]") |> Enum.count() == 0
    end

    test "renders the You leave with panel with its four items and no address or email",
         %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert text_of(main, "#hitme-leave-with h3") == "You leave with"

      assert texts(main, "#hitme-leave-items li") == [
               "A working backlog",
               "Agents connected to it",
               "Part of your POC",
               "A team ready to run it"
             ]

      assert main |> LazyHTML.query("#hitme-leave-with a") |> Enum.count() == 0
      refute text_of(main, "#hitme-leave-with") =~ "LikeABoss.com/HitMe"
      refute text_of(main, "#hitme-leave-with") =~ "enterprise@letstango.ca"

      # The navy steps come before the cyan panel, so they stack first on mobile.
      assert main
             |> LazyHTML.query("#hitme-back > div")
             |> Enum.flat_map(&LazyHTML.attribute(&1, "class")) ==
               ["hitme-back-main", "hitme-leave"]
    end

    test "renders no QR code: the sticker is the only image on the page", %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert main |> LazyHTML.query("img") |> Enum.flat_map(&LazyHTML.attribute(&1, "id")) ==
               ["hitme-sticker"]

      assert main |> LazyHTML.query("svg, canvas, picture, object, iframe") |> Enum.count() == 0
      refute LazyHTML.to_html(main) =~ ~r/qr[-_ ]?code|\bqr\b/i
    end

    test "renders the three Why Stride points", %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert text_of(main, "#hitme-why-heading") == "Why Stride"

      assert texts(main, "#hitme-why-points li") == [
               "Agents work from tasks your team has written and prioritized, not from a chat window.",
               "Your tests must pass before an agent can finish a task.",
               "You decide which tasks wait for a person's sign-off before they are Done."
             ]
    end

    test "the closing email button has the same mailto href as the booking bar's", %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      [top_href] = main |> LazyHTML.query("#hitme-top-button") |> LazyHTML.attribute("href")

      assert main |> LazyHTML.query("#hitme-closing-button") |> LazyHTML.attribute("href") ==
               [top_href]

      assert text_of(main, "#hitme-closing-heading") == "Book a half-day session"
      assert text_of(main, "#hitme-closing-button") == "Email us to book a session"
      assert text_of(main, "#hitme-closing-email") == "enterprise@letstango.ca"

      assert main |> LazyHTML.query("#hitme-closing-email") |> LazyHTML.attribute("href") ==
               ["mailto:enterprise@letstango.ca"]
    end

    test "the booking bar above the hero repeats the closing offer and mails the same address",
         %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert text_of(main, "#hitme-top-heading") == text_of(main, "#hitme-closing-heading")

      assert text_of(main, "#hitme-top .hitme-top-lead") ==
               text_of(main, "#hitme-closing .hitme-lead")

      assert text_of(main, "#hitme-top-button") == "Email us to book a session"

      assert main |> LazyHTML.query("#hitme-top-button") |> LazyHTML.attribute("href") == [
               PageHTML.hit_me_mailto()
             ]

      assert text_of(main, "#hitme-top-email") == "enterprise@letstango.ca"

      assert main |> LazyHTML.query("#hitme-top-email") |> LazyHTML.attribute("href") ==
               ["mailto:enterprise@letstango.ca"]
    end

    test "the booking bar has no heading element, so the hero's h1 is the first heading",
         %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert main |> LazyHTML.query("#hitme-top :is(h1, h2, h3, h4, h5, h6)") |> Enum.count() == 0
      assert [first | _] = main |> LazyHTML.query("h1, h2, h3, h4, h5, h6") |> Enum.to_list()
      assert first |> LazyHTML.attribute("id") == ["hitme-heading"]
    end

    test "with the de locale the booking bar is translated", %{conn: conn} do
      main = main_in(conn, "de")

      refute text_of(main, "#hitme-top-heading") == "Book a half-day session"
      assert text_of(main, "#hitme-top-heading") == text_of(main, "#hitme-closing-heading")
    end

    test "renders the sections in order below the hero, with unique ids", %{conn: conn} do
      main = conn |> get(~p"/HitMe") |> html_response(200) |> main()

      assert main |> LazyHTML.query("section[id]") |> Enum.flat_map(&LazyHTML.attribute(&1, "id")) ==
               ~w(hitme-top hitme-hero hitme-back hitme-why hitme-closing)

      ids = main |> LazyHTML.query("[id]") |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
      assert ids == Enum.uniq(ids)
    end

    test "with the de locale renders the translated Why Stride heading and keeps the highlights",
         %{conn: conn} do
      main = main_in(conn, "de")

      assert text_of(main, "#hitme-why-heading") == "Warum Stride"
      refute LazyHTML.text(main) =~ "Why Stride"

      assert texts(main, "#hitme-back-heading .hitme-accent") == ["Tatendrang", "Wissen"]
      assert length(texts(main, "#hitme-steps .hitme-step-strong")) == 5
      refute LazyHTML.text(main) =~ ~r/\{[a-z_]+\}/
    end

    test "with the ja locale renders a highlight the translation moved mid-sentence",
         %{conn: conn} do
      main = main_in(conn, "ja")

      step_03 = main |> LazyHTML.query("#hitme-steps .hitme-step-text") |> Enum.at(2)

      assert step_03 |> LazyHTML.text() |> String.trim() ==
               "レビューに進む前にあなたのテストが実行されます。"

      assert step_03 |> LazyHTML.query(".hitme-step-strong") |> LazyHTML.text() ==
               "あなたのテストが実行されます"

      refute LazyHTML.text(main) =~ ~r/\{[a-z_]+\}/
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

    test "a long translated heading wraps inside the card", %{css: css} do
      assert rule(css, ".stride-marketing .hitme-heading") =~ "overflow-wrap: anywhere"
    end

    test "the back card clips its corners and splits about 70/30 from 768px", %{css: css} do
      back = rule(css, ".stride-marketing .hitme-back")

      assert back =~ "overflow: hidden"
      # Text that sets no colour of its own must not inherit the page's dark ink.
      assert back =~ "color: var(--hitme-white);"
      assert back =~ "grid-template-columns: minmax(0, 1fr);"
      # rule/2 finds the base rule first, so match the desktop split directly.
      assert css =~ "grid-template-columns: minmax(0, 2.4fr) minmax(0, 1fr);"
    end

    test "long translated step and panel text wraps inside its card", %{css: css} do
      for selector <- ~w(.hitme-back-heading .hitme-step-text .hitme-leave-items
                         .hitme-panel-heading .hitme-top-heading .hitme-top-lead) do
        assert rule(css, ".stride-marketing #{selector}") =~ "overflow-wrap: anywhere",
               "#{selector} must wrap long words"
      end
    end

    test "the cyan panel's text is the on-cyan token, the pair the contrast gate checks",
         %{css: css} do
      leave = rule(css, ".stride-marketing .hitme-leave")

      assert leave =~ "background: var(--hitme-cyan);"
      assert leave =~ "color: var(--hitme-on-cyan);"
    end

    test "on narrow screens the sticker is capped below the card's width", %{css: css} do
      sticker = rule(css, ".stride-marketing .hitme-sticker")

      assert sticker =~ "width: 220px"
      assert sticker =~ "max-width: 70%"
    end
  end

  describe "PageHTML /HitMe helpers" do
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
