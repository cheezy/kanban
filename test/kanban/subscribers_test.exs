defmodule Kanban.SubscribersTest do
  # async: false — the rate-limit describe block changes the global
  # Kanban.RateLimit config.
  use Kanban.DataCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Swoosh.TestAssertions

  alias Kanban.Repo
  alias Kanban.Subscribers
  alias Kanban.Subscribers.Subscriber
  alias Kanban.Subscribers.SubscriberToken

  @consent "I agree to receive release announcements."

  defp unique_email, do: "release-#{System.unique_integer([:positive])}@example.test"

  defp random_ip, do: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}

  defp subscribe(email, opts \\ []) do
    Subscribers.subscribe(
      email,
      Keyword.merge([ip: random_ip(), locale: "en", consent_text: @consent], opts)
    )
  end

  # Subscribes and returns the {confirm, unsubscribe} tokens from the one
  # confirmation email it sends.
  defp subscribe_and_receive(email, opts \\ []) do
    assert :ok = subscribe(email, opts)
    assert_received {:email, sent}
    tokens(sent)
  end

  defp tokens(sent) do
    [confirm] =
      Regex.run(~r{/releases/confirm\?token=([A-Za-z0-9_-]+)}, sent.text_body,
        capture: :all_but_first
      )

    [unsubscribe] =
      Regex.run(~r{/releases/unsubscribe\?token=([A-Za-z0-9_-]+)}, sent.text_body,
        capture: :all_but_first
      )

    {confirm, unsubscribe}
  end

  defp age_tokens(context, days) do
    past = :second |> DateTime.utc_now() |> DateTime.add(-days * 86_400)

    SubscriberToken
    |> where([t], t.context == ^context)
    |> Repo.update_all(set: [inserted_at: past])
  end

  describe "subscribe/2" do
    test "subscribing stores a pending subscriber with its locale and consent and sends one confirmation email" do
      email = unique_email()
      assert :ok = subscribe(email, locale: "de")

      subscriber = Subscribers.get_subscriber_by_email(email)
      assert subscriber.status == :pending
      assert subscriber.locale == "de"
      assert subscriber.consent_text == @consent
      assert %DateTime{} = subscriber.consented_at
      assert DateTime.diff(DateTime.utc_now(), subscriber.consented_at) < 60
      assert subscriber.confirmed_at == nil

      assert_email_sent(fn sent ->
        assert sent.to == [{"", email}]
        assert sent.subject =~ "[Stride] "
      end)

      refute_received {:email, _second}
    end

    test "stores a trimmed address and resolves an unknown locale to English" do
      email = unique_email()
      assert :ok = subscribe("  " <> email <> " ", locale: "xx-YY")

      assert %Subscriber{email: ^email, locale: "en"} = Subscribers.get_subscriber_by_email(email)
    end

    test "subscribing an address twice, in any letter case, sends no second email and reveals nothing" do
      email = unique_email()
      assert :ok = subscribe(email)
      assert_received {:email, _first}

      assert :ok = subscribe(String.upcase(email))
      refute_received {:email, _second}

      assert Repo.aggregate(Subscriber, :count) == 1

      active_email = unique_email()
      {confirm, _unsubscribe} = subscribe_and_receive(active_email)
      {:ok, _active} = Subscribers.confirm(confirm)

      assert :ok = subscribe(String.upcase(active_email))
      refute_received {:email, _third}
      assert Subscribers.get_subscriber_by_email(active_email).status == :active
      assert Repo.aggregate(Subscriber, :count) == 2
    end

    test "a pending address whose confirmation expired is sent one new confirmation" do
      email = unique_email()
      {old_confirm, _unsubscribe} = subscribe_and_receive(email, locale: "en")
      age_tokens("confirm", 8)

      assert :ok = subscribe(email, locale: "fr", consent_text: "renewed")
      assert_received {:email, sent}
      refute_received {:email, _another}

      {new_confirm, _new_unsubscribe} = tokens(sent)
      assert Subscribers.confirm(old_confirm) == :error

      subscriber = Subscribers.get_subscriber_by_email(email)
      assert subscriber.locale == "fr"
      assert subscriber.consent_text == "renewed"
      assert {:ok, %Subscriber{status: :active}} = Subscribers.confirm(new_confirm)
    end

    test "an empty or malformed address is refused with a translated message" do
      for bad <- ["", "   ", nil, "no-at-sign", "a b@example.test", "a@b@c"] do
        assert {:error, %Ecto.Changeset{} = changeset} = subscribe(bad)
        assert %{email: [_ | _]} = errors_on(changeset)
      end

      assert {:error, changeset} = subscribe("no-at-sign")

      german =
        Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
          changeset.errors
          |> Keyword.get_values(:email)
          |> Enum.map(&KanbanWeb.CoreComponents.translate_error/1)
        end)

      assert german == ["muss das @-Zeichen enthalten und darf keine Leerzeichen enthalten"]

      assert Repo.aggregate(Subscriber, :count) == 0
      assert_no_email_sent()
    end

    test "an address with an invisible character or a trailing dot is refused, so it cannot pose as a new address" do
      email = unique_email()
      [local, domain] = String.split(email, "@")

      variants = [
        email <> ".",
        email <> "\u200B",
        local <> "\u200B@" <> domain,
        email <> "\uFEFF",
        email <> "\u2060",
        email <> "\u00AD",
        email <> "\u0007"
      ]

      for variant <- variants do
        assert {:error, %Ecto.Changeset{} = changeset} = subscribe(variant)
        assert %{email: [_ | _]} = errors_on(changeset)
      end

      assert Repo.aggregate(Subscriber, :count) == 0
      assert_no_email_sent()
      assert :ok = subscribe("first.last@sub.example.test")
    end

    test "an address longer than 160 characters is refused" do
      long = String.duplicate("a", 160) <> "@example.test"
      assert {:error, changeset} = subscribe(long)
      assert %{email: [_]} = errors_on(changeset)
    end

    test "a signed-in user's address subscribes like any other, and no account joins by itself" do
      user = user_fixture()
      assert Repo.aggregate(Subscriber, :count) == 0

      assert :ok = subscribe(user.email)
      assert %Subscriber{status: :pending} = Subscribers.get_subscriber_by_email(user.email)
      assert Repo.aggregate(Subscriber, :count) == 1
    end
  end

  describe "confirm/1" do
    test "confirming with the emailed token activates the subscriber" do
      email = unique_email()
      {confirm, _unsubscribe} = subscribe_and_receive(email)
      assert Subscribers.confirm_token_valid?(confirm)

      assert {:ok, %Subscriber{status: :active, confirmed_at: %DateTime{}}} =
               Subscribers.confirm(confirm)

      assert Subscribers.get_subscriber_by_email(email).status == :active
      refute Subscribers.confirm_token_valid?(confirm)
      assert Subscribers.confirm(confirm) == :error
    end

    test "an expired or unknown token is refused" do
      email = unique_email()
      {confirm, unsubscribe} = subscribe_and_receive(email)

      for bad <- [
            nil,
            42,
            "",
            "not base64!",
            Base.url_encode64("short", padding: false),
            unsubscribe
          ] do
        refute Subscribers.confirm_token_valid?(bad)
        assert Subscribers.confirm(bad) == :error
      end

      refute Subscribers.unsubscribe_token_valid?(confirm)
      assert Subscribers.unsubscribe(confirm) == :error

      age_tokens("confirm", 8)
      refute Subscribers.confirm_token_valid?(confirm)
      assert Subscribers.confirm(confirm) == :error
      assert Subscribers.get_subscriber_by_email(email).status == :pending

      age_tokens("unsubscribe", 91)
      refute Subscribers.unsubscribe_token_valid?(unsubscribe)
      assert Subscribers.unsubscribe(unsubscribe) == :error
    end

    test "stores only the hash of each token" do
      {confirm, unsubscribe} = subscribe_and_receive(unique_email())
      hashes = SubscriberToken |> select([t], t.token_hash) |> Repo.all()

      assert length(hashes) == 2

      for token <- [confirm, unsubscribe] do
        raw = Base.url_decode64!(token, padding: false)
        refute raw in hashes
        assert :crypto.hash(:sha256, raw) in hashes
      end
    end
  end

  describe "unsubscribe/1" do
    test "unsubscribing with the emailed link removes the subscriber" do
      email = unique_email()
      {confirm, unsubscribe} = subscribe_and_receive(email)
      {:ok, _subscriber} = Subscribers.confirm(confirm)

      assert Subscribers.unsubscribe_token_valid?(unsubscribe)
      assert Subscribers.unsubscribe(unsubscribe) == :ok

      assert Subscribers.get_subscriber_by_email(email) == nil
      assert Repo.aggregate(SubscriberToken, :count) == 0
      assert Subscribers.unsubscribe(unsubscribe) == :error
    end

    test "a pending subscriber can unsubscribe before confirming" do
      email = unique_email()
      {_confirm, unsubscribe} = subscribe_and_receive(email)

      assert Subscribers.unsubscribe(unsubscribe) == :ok
      assert Subscribers.get_subscriber_by_email(email) == nil
    end

    test "issue_unsubscribe_token/1 gives every email its own working link" do
      email = unique_email()
      {_confirm, first} = subscribe_and_receive(email)

      second =
        email |> Subscribers.get_subscriber_by_email() |> Subscribers.issue_unsubscribe_token()

      assert first != second
      assert Subscribers.unsubscribe_token_valid?(first)
      assert Subscribers.unsubscribe_token_valid?(second)
      assert Subscribers.unsubscribe(first) == :ok
    end
  end

  describe "confirm/1 and unsubscribe/1 together" do
    # Records the SQL each Repo query runs, in order, so a test can check
    # which statement touches which table first.
    defp record_queries(fun) do
      test_pid = self()
      handler_id = "subscribers-lock-order-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:kanban, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == test_pid, do: send(test_pid, {:query, metadata.query})
          end,
          nil
        )

      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

      collect_queries([])
    end

    defp collect_queries(acc) do
      receive do
        {:query, sql} -> collect_queries([sql | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp writes(queries),
      do: Enum.filter(queries, &(&1 =~ ~r/^(DELETE|UPDATE)|FOR UPDATE/))

    test "confirm and unsubscribe both lock the subscriber row before writing anything" do
      {confirm, unsubscribe} = subscribe_and_receive(unique_email())

      for operation <- [
            fn -> Subscribers.confirm(confirm) end,
            fn -> Subscribers.unsubscribe(unsubscribe) end
          ] do
        assert [first | rest] = operation |> record_queries() |> writes()
        assert first =~ ~r/FROM "subscribers".*FOR UPDATE/s
        assert rest != []
        refute Enum.any?(rest, &(&1 =~ "FOR UPDATE"))
      end
    end

    test "a confirm after the subscriber unsubscribed is refused, not raised" do
      email = unique_email()
      {confirm, unsubscribe} = subscribe_and_receive(email)

      assert Subscribers.unsubscribe(unsubscribe) == :ok
      assert Subscribers.confirm(confirm) == :error
      assert Subscribers.get_subscriber_by_email(email) == nil
    end
  end

  describe "purge_unconfirmed/2" do
    test "deletes pending subscribers whose confirmation link expired, with their tokens, in batches" do
      stale = for _ <- 1..3, do: unique_email()
      Enum.each(stale, &subscribe_and_receive/1)
      age_tokens("confirm", 8)

      fresh = unique_email()
      subscribe_and_receive(fresh)

      {active_confirm, _unsubscribe} = subscribe_and_receive(active = unique_email())
      {:ok, _subscriber} = Subscribers.confirm(active_confirm)
      SubscriberToken |> Repo.update_all(set: [inserted_at: ~U[2020-01-01 00:00:00Z]])
      fresh_subscriber = Subscribers.get_subscriber_by_email(fresh)

      fresh_subscriber
      |> SubscriberToken.by_subscriber_query("confirm")
      |> Repo.update_all(set: [inserted_at: DateTime.utc_now(:second)])

      now = DateTime.utc_now(:second)
      assert Subscribers.purge_unconfirmed(now, 2) == 3

      for email <- stale, do: assert(Subscribers.get_subscriber_by_email(email) == nil)
      assert %Subscriber{status: :pending} = Subscribers.get_subscriber_by_email(fresh)
      assert %Subscriber{status: :active} = Subscribers.get_subscriber_by_email(active)

      remaining = SubscriberToken |> select([t], t.subscriber_id) |> distinct(true) |> Repo.all()

      assert Enum.sort(remaining) ==
               Enum.sort([fresh_subscriber.id, Subscribers.get_subscriber_by_email(active).id])

      assert Subscribers.purge_unconfirmed(now, 2) == 0
    end

    test "a pending subscriber is kept until its link is more than 7 days old" do
      email = unique_email()
      subscribe_and_receive(email)
      age_tokens("confirm", 6)

      now = DateTime.utc_now(:second)
      assert Subscribers.purge_unconfirmed(now, 10) == 0
      assert Subscribers.get_subscriber_by_email(email)

      two_days_later = DateTime.add(now, 2, :day)
      assert Subscribers.purge_unconfirmed(two_days_later, 10) == 1
    end
  end

  describe "get_subscriber_by_email/1" do
    test "finds an address in any letter case" do
      email = unique_email()
      assert :ok = subscribe(email)

      assert %Subscriber{email: ^email} =
               email |> String.upcase() |> Subscribers.get_subscriber_by_email()

      assert Subscribers.get_subscriber_by_email(unique_email()) == nil
    end
  end

  describe "rate limiting" do
    setup do
      original = Application.get_env(:kanban, Kanban.RateLimit)

      Application.put_env(:kanban, Kanban.RateLimit,
        enabled: true,
        release_signup: %{scale_ms: 60_000, ip_limit: 2}
      )

      on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

      %{ip: random_ip()}
    end

    test "signups are rate-limited per IP", %{ip: ip} do
      assert :ok = subscribe(unique_email(), ip: ip)
      assert :ok = subscribe(unique_email(), ip: ip)
      assert_received {:email, _first}
      assert_received {:email, _second}

      email = unique_email()
      assert {:error, :rate_limited} = subscribe(email, ip: ip)
      refute_received {:email, _third}
      assert Subscribers.get_subscriber_by_email(email) == nil

      assert {:error, :rate_limited} = subscribe("malformed", ip: ip)

      other_ip = {11, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
      assert :ok = subscribe(unique_email(), ip: other_ip)
    end
  end
end
