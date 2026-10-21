defmodule KanbanWeb.TwoFactorPendingTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures

  alias KanbanWeb.TwoFactorPending

  doctest KanbanWeb.TwoFactorPending

  describe "new/3 and fetch/2" do
    test "round-trips the user id and the remember-me choice" do
      for remember_me <- [true, false] do
        marker = TwoFactorPending.new(42, remember_me, 5_000)

        assert TwoFactorPending.fetch(marker, 5_010) ==
                 {:ok, %{user_id: 42, remember_me: remember_me}}
      end
    end

    test "accepts a marker exactly ttl_seconds old and refuses one a second older" do
      marker = TwoFactorPending.new(42, false, 5_000)
      ttl = TwoFactorPending.ttl_seconds()

      assert ttl == 300
      assert {:ok, _pending} = TwoFactorPending.fetch(marker, 5_000 + ttl)
      assert TwoFactorPending.fetch(marker, 5_000 + ttl + 1) == {:error, :expired}
    end

    test "refuses a marker issued in the future" do
      marker = TwoFactorPending.new(42, false, 5_000)

      assert TwoFactorPending.fetch(marker, 4_999) == {:error, :expired}
    end

    test "refuses a missing or malformed marker" do
      for marker <- [
            nil,
            %{},
            "marker",
            %{"user_id" => "42", "issued_at" => 5_000, "remember_me" => false},
            %{"user_id" => 42, "issued_at" => "5000", "remember_me" => false},
            %{"user_id" => 42, "issued_at" => 5_000, "remember_me" => "true"}
          ] do
        assert TwoFactorPending.fetch(marker, 5_000) == {:error, :expired}
      end
    end
  end

  describe "put_sso_link/3" do
    test "stores the link with the user id and never remembers the device", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(user_return_to: "/boards/1")
        |> TwoFactorPending.put_sso_link(user, %{connection_id: 3, subject: "abc"})

      assert {:ok, %{user_id: id, remember_me: false, sso_link: link}} =
               TwoFactorPending.get(conn)

      assert id == user.id
      assert link == %{connection_id: 3, subject: "abc"}
      assert get_session(conn, :user_return_to) == "/boards/1"
    end

    test "drops a return path that would not fit in the session cookie with the subject" do
      session_opts =
        Plug.Session.init(store: :cookie, key: "_kanban_key", signing_salt: "MkVVRya+")

      subject = String.duplicate("s", 1024)
      long_path = "/" <> String.duplicate("p", 2047)
      user = %Kanban.Accounts.User{id: 1_234_567}

      conn =
        build_conn(:post, "/users/sso/saml/1/acs")
        |> Map.put(:secret_key_base, KanbanWeb.Endpoint.config(:secret_key_base))
        |> Plug.Session.call(session_opts)
        |> fetch_session()
        |> put_session(:user_return_to, long_path)
        |> TwoFactorPending.put_sso_link(user, %{connection_id: 123_456, subject: subject})

      assert get_session(conn, :user_return_to) == nil
      assert {:ok, %{sso_link: %{subject: ^subject}}} = TwoFactorPending.get(conn)
      assert byte_size(send_resp(conn, 302, "").resp_cookies["_kanban_key"].value) < 4096

      fits = "/" <> String.duplicate("p", 1023)

      conn =
        build_conn()
        |> init_test_session(user_return_to: fits)
        |> TwoFactorPending.put_sso_link(user, %{connection_id: 1, subject: subject})

      assert get_session(conn, :user_return_to) == fits
    end

    test "a malformed link refuses the whole marker" do
      for sso <- [
            %{},
            "link",
            %{"connection_id" => "3", "subject" => "abc"},
            %{"connection_id" => 3, "subject" => ""},
            %{"connection_id" => 3, "subject" => 7}
          ] do
        marker = 42 |> TwoFactorPending.new(false, 5_000) |> Map.put("sso", sso)

        assert TwoFactorPending.fetch(marker, 5_000) == {:error, :expired}
      end
    end
  end

  describe "from_session/2" do
    test "reads the marker from a string-keyed LiveView session" do
      session = %{"two_factor_pending" => TwoFactorPending.new(42, true, 5_000)}

      assert TwoFactorPending.from_session(session, 5_100) ==
               {:ok, %{user_id: 42, remember_me: true}}

      assert TwoFactorPending.from_session(%{}, 5_100) == {:error, :expired}
    end
  end

  describe "put/3, get/2 and delete/1" do
    test "store the marker in the session without renewing it", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(user_return_to: "/boards/1")
        |> TwoFactorPending.put(user, true)

      assert {:ok, %{user_id: id, remember_me: true}} = TwoFactorPending.get(conn)
      assert id == user.id
      assert get_session(conn, :user_return_to) == "/boards/1"

      conn = TwoFactorPending.delete(conn)

      assert TwoFactorPending.get(conn) == {:error, :expired}
      assert get_session(conn, :user_return_to) == "/boards/1"
    end
  end
end
