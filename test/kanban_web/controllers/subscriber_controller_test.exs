defmodule KanbanWeb.SubscriberControllerTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Swoosh.TestAssertions

  alias Kanban.Repo
  alias Kanban.Subscribers
  alias Kanban.Subscribers.Subscriber

  @check_inbox "Thanks! Check your inbox: if this address is not on the list yet, we have sent it a link to confirm your subscription."

  defp unique_email, do: "release-#{System.unique_integer([:positive])}@example.test"

  defp with_ip(conn),
    do: %{conn | remote_ip: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}}

  defp signup(conn, email) do
    conn |> with_ip() |> post(~p"/releases/subscribe", %{"subscriber" => %{"email" => email}})
  end

  defp in_german(conn), do: Plug.Test.init_test_session(conn, %{"locale" => "de"})

  # The confirmation email's links, as a page visitor would follow them.
  defp sent_links do
    assert_received {:email, sent}

    [confirm] =
      Regex.run(~r{https?://[^/\s]+(/releases/confirm\?[^\s]+)}, sent.text_body,
        capture: :all_but_first
      )

    [unsubscribe] =
      Regex.run(~r{https?://[^/\s]+(/releases/unsubscribe\?[^\s]+)}, sent.text_body,
        capture: :all_but_first
      )

    %{confirm: confirm, unsubscribe: unsubscribe}
  end

  defp token(path),
    do: path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("token")

  describe "the /changelog signup form" do
    test "renders an empty email field and posts with a CSRF token to the signup route", %{
      conn: conn
    } do
      document = conn |> get(~p"/changelog") |> html_response(200) |> LazyHTML.from_document()
      form = LazyHTML.query(document, "[data-changelog] aside#release-signup form")

      assert LazyHTML.attribute(form, "action") == ["/releases/subscribe"]
      assert LazyHTML.attribute(form, "method") == ["post"]
      assert form |> LazyHTML.query(~s(input[name="_csrf_token"])) |> Enum.count() == 1

      email = LazyHTML.query(form, ~s(input[name="subscriber[email]"]))
      assert LazyHTML.attribute(email, "type") == ["email"]
      assert LazyHTML.attribute(email, "value") in [[], [""]]

      assert document
             |> LazyHTML.query("[data-changelog] section #release-signup")
             |> Enum.count() ==
               0
    end

    for locale <- ~w(de es fr ja pt zh) do
      test "is translated under #{locale}", %{conn: conn} do
        text =
          conn
          |> Plug.Test.init_test_session(%{"locale" => unquote(locale)})
          |> get(~p"/changelog")
          |> html_response(200)
          |> LazyHTML.from_document()
          |> LazyHTML.query("#release-signup")
          |> LazyHTML.text()

        for english <- [
              "Get release announcements",
              "Leave your email address",
              "Email address",
              "I agree to receive",
              "Subscribe"
            ] do
          refute text =~ english, "#{unquote(locale)} shows #{inspect(english)}"
        end
      end
    end
  end

  describe "POST /releases/subscribe" do
    test "the changelog form posts and shows the same translated check-your-email message for a new or an existing address",
         %{conn: conn} do
      email = unique_email()

      new = signup(build_conn(), email)
      assert redirected_to(new) == ~p"/changelog"
      assert Phoenix.Flash.get(new.assigns.flash, :info) == @check_inbox
      assert_received {:email, _confirmation}

      existing = signup(build_conn(), String.upcase(email))
      assert existing.status == new.status
      assert redirected_to(existing) == redirected_to(new)
      assert existing.assigns.flash == new.assigns.flash
      refute_received {:email, _second}

      german = conn |> in_german() |> signup(unique_email())
      german_message = Phoenix.Flash.get(german.assigns.flash, :info)
      assert german_message != @check_inbox
      assert german_message =~ "Posteingang"

      followed = conn |> recycle() |> get(redirected_to(new))
      refute html_response(followed, 200) =~ email
    end

    test "stores the visitor's locale and the consent text the form showed", %{conn: conn} do
      email = unique_email()
      conn |> in_german() |> signup(email)

      subscriber = Subscribers.get_subscriber_by_email(email)
      assert subscriber.locale == "de"

      assert subscriber.consent_text ==
               Gettext.with_locale(
                 KanbanWeb.Gettext,
                 "de",
                 &KanbanWeb.ReleaseSignupForm.consent_text/0
               )

      assert_email_sent(fn sent -> assert sent.subject =~ "Abonnement" end)
    end

    test "a malformed address is refused with a translated message and no email", %{conn: conn} do
      conn = signup(conn, "not-an-address")

      assert redirected_to(conn) == ~p"/changelog"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Enter a valid email address to subscribe."

      assert_no_email_sent()

      missing = build_conn() |> with_ip() |> post(~p"/releases/subscribe", %{})
      assert Phoenix.Flash.get(missing.assigns.flash, :error) =~ "valid email"
      assert Repo.aggregate(Subscriber, :count) == 0
    end

    test "a signed-in user subscribes their address only when they submit it", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      form =
        conn
        |> get(~p"/changelog")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#release-signup")

      refute LazyHTML.to_html(form) =~ user.email

      email_input = LazyHTML.query(form, ~s(input[name="subscriber[email]"]))
      assert LazyHTML.attribute(email_input, "value") in [[], [""]]

      assert Repo.aggregate(Subscriber, :count) == 0

      conn |> recycle() |> log_in_user(user) |> signup(user.email)
      assert %Subscriber{status: :pending} = Subscribers.get_subscriber_by_email(user.email)
    end

    test "GET on the signup route does not subscribe anyone", %{conn: conn} do
      conn =
        get(
          conn,
          "/releases/subscribe?" <> URI.encode_query(%{"subscriber[email]" => unique_email()})
        )

      assert conn.status == 404

      assert Repo.aggregate(Subscriber, :count) == 0
      assert_no_email_sent()
    end

    test "the signup requires the CSRF token", %{conn: conn} do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> Plug.Test.init_test_session(%{})
        |> signup(unique_email())
      end
    end
  end

  describe "confirm" do
    test "the confirm link activates the subscriber and shows a translated confirmation page",
         %{conn: conn} do
      email = unique_email()
      conn |> in_german() |> signup(email)
      %{confirm: confirm} = sent_links()
      assert confirm =~ "locale=de"

      prompt = build_conn() |> get(confirm)
      body = html_response(prompt, 200)
      assert body =~ ~s(data-state="confirm_prompt")
      assert body =~ "Abonnement bestätigen"
      refute body =~ email
      assert get_resp_header(prompt, "referrer-policy") == ["no-referrer"]
      assert Subscribers.get_subscriber_by_email(email).status == :pending

      done = build_conn() |> in_german() |> post(~p"/releases/confirm?#{[token: token(confirm)]}")
      body = html_response(done, 200)
      assert body =~ ~s(data-state="confirmed")
      refute body =~ "You're subscribed"
      refute body =~ email
      assert Subscribers.get_subscriber_by_email(email).status == :active
    end

    test "an invalid, expired or used confirm link shows the same generic page", %{conn: conn} do
      signup(conn, unique_email())
      %{confirm: confirm} = sent_links()
      token = token(confirm)

      {:ok, _subscriber} = Subscribers.confirm(token)

      for response <- [
            get(build_conn(), ~p"/releases/confirm?#{[token: token]}"),
            get(build_conn(), ~p"/releases/confirm?#{[token: "nope"]}"),
            get(build_conn(), ~p"/releases/confirm"),
            post(build_conn(), ~p"/releases/confirm?#{[token: token]}")
          ] do
        body = html_response(response, 400)
        assert body =~ ~s(data-state="invalid")
        assert body =~ "This link is no longer valid"
      end
    end
  end

  describe "unsubscribe" do
    test "the unsubscribe page changes nothing and its form removes the subscriber", %{conn: conn} do
      email = unique_email()
      signup(conn, email)
      %{unsubscribe: unsubscribe} = sent_links()

      prompt = build_conn() |> get(unsubscribe)
      body = html_response(prompt, 200)
      assert body =~ ~s(data-state="unsubscribe_prompt")
      refute body =~ email
      assert get_resp_header(prompt, "referrer-policy") == ["no-referrer"]
      assert Subscribers.get_subscriber_by_email(email)

      one_click_page =
        get(build_conn(), ~p"/releases/unsubscribe/one-click?#{[token: token(unsubscribe)]}")

      assert redirected_to(one_click_page) ==
               ~p"/releases/unsubscribe?#{[token: token(unsubscribe)]}"

      assert html_response(get(build_conn(), redirected_to(one_click_page)), 200) =~
               ~s(data-state="unsubscribe_prompt")

      assert Subscribers.get_subscriber_by_email(email)

      done = post(build_conn(), ~p"/releases/unsubscribe?#{[token: token(unsubscribe)]}")
      assert html_response(done, 200) =~ ~s(data-state="unsubscribed")
      assert Subscribers.get_subscriber_by_email(email) == nil

      again = post(build_conn(), ~p"/releases/unsubscribe?#{[token: token(unsubscribe)]}")
      assert html_response(again, 400) =~ ~s(data-state="invalid")
      assert html_response(get(build_conn(), ~p"/releases/unsubscribe"), 400) =~ "no longer valid"
    end

    test "RFC 8058 one-click POST unsubscribes without a session or CSRF token", %{conn: conn} do
      email = unique_email()
      signup(conn, email)
      %{unsubscribe: unsubscribe} = sent_links()
      path = ~p"/releases/unsubscribe/one-click?#{[token: token(unsubscribe)]}"

      csrf_on = fn -> Plug.Conn.put_private(build_conn(), :plug_skip_csrf_protection, false) end

      assert response(post(csrf_on.(), path, %{}), 400) == ""
      assert Subscribers.get_subscriber_by_email(email)

      bad = ~p"/releases/unsubscribe/one-click?#{[token: "nope"]}"
      assert response(post(csrf_on.(), bad, %{"List-Unsubscribe" => "One-Click"}), 400) == ""

      # RFC 8058 puts the marker in the POST body; in the URL alone it is
      # what a link scanner replaying the URL would send, so it does nothing.
      marker_in_url =
        ~p"/releases/unsubscribe/one-click?#{[token: token(unsubscribe), "List-Unsubscribe": "One-Click"]}"

      assert response(post(csrf_on.(), marker_in_url), 400) == ""
      assert Subscribers.get_subscriber_by_email(email)

      ok = post(csrf_on.(), path, %{"List-Unsubscribe" => "One-Click"})
      assert response(ok, 200) == ""
      assert Subscribers.get_subscriber_by_email(email) == nil
    end
  end

  describe "the confirm and unsubscribe prompts" do
    test "never write the token into the page and post back to their own URL", %{conn: conn} do
      email = unique_email()
      signup(conn, email)
      %{confirm: confirm, unsubscribe: unsubscribe} = sent_links()

      for {link, done_state} <- [{confirm, "confirmed"}, {unsubscribe, "unsubscribed"}] do
        prompt = build_conn() |> get(link)
        body = html_response(prompt, 200)
        refute body =~ token(link)

        form = body |> LazyHTML.from_document() |> LazyHTML.query("#release-subscription form")
        assert Enum.count(form) == 1
        assert LazyHTML.attribute(form, "action") == []
        assert LazyHTML.attribute(form, "method") == ["post"]
        assert form |> LazyHTML.query(~s(input[name="_csrf_token"])) |> Enum.count() == 1

        # A form with no action posts to the page's own URL, query included.
        done = prompt |> recycle() |> post(link)
        assert html_response(done, 200) =~ ~s(data-state="#{done_state}")
      end
    end
  end

  describe "the confirm and unsubscribe pages in every locale" do
    # Every English string the five page states render, page titles included.
    @english_copy [
      "Confirm your subscription",
      "Confirm to receive an email when a new version of Stride is released.",
      "Confirm subscription",
      "You&#39;re subscribed",
      "You will receive an email when a new version of Stride is released.",
      "Unsubscribe from release announcements",
      "This address will be removed from the list at once.",
      # The button label sits on its own line inside primary_full_button, so
      # the match allows the whitespace around it.
      ~r/>\s*Unsubscribe\s*</,
      "You&#39;re unsubscribed",
      "This address has been removed from the release announcement list.",
      "This link is no longer valid",
      "The link is invalid, has expired or was already used.",
      "Back to the changelog"
    ]

    for locale <- ~w(de es fr ja pt zh) do
      test "renders all five states translated under #{locale}" do
        locale = unquote(locale)

        :ok =
          Subscribers.subscribe(unique_email(),
            ip: {10, 9, 8, 7},
            locale: locale,
            consent_text: "consent"
          )

        %{confirm: confirm, unsubscribe: unsubscribe} = sent_links()
        assert confirm =~ "locale=#{locale}"
        assert unsubscribe =~ "locale=#{locale}"

        states = [
          {"confirm_prompt", 200, get(build_conn(), confirm)},
          {"confirmed", 200, post(build_conn(), confirm)},
          {"unsubscribe_prompt", 200, get(build_conn(), unsubscribe)},
          {"unsubscribed", 200, post(build_conn(), unsubscribe)},
          {"invalid", 400, get(build_conn(), ~p"/releases/confirm?#{[locale: locale]}")}
        ]

        for {state, status, response} <- states do
          body = html_response(response, status)
          assert body =~ ~s(data-state="#{state}"), "#{locale} #{state}"

          for english <- @english_copy do
            refute body =~ english, "#{locale} #{state} shows #{inspect(english)}"
          end
        end
      end
    end
  end
end
