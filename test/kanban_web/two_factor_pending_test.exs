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
