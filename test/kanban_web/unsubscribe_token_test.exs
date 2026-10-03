defmodule KanbanWeb.UnsubscribeTokenTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.UnsubscribeToken

  @max_age 90 * 24 * 60 * 60

  describe "sign/3 and verify/1" do
    test "round-trips the user id and event type" do
      token = UnsubscribeToken.sign(42, :review_requested)

      assert {:ok, %{user_id: 42, event_type: :review_requested}} = UnsubscribeToken.verify(token)
    end

    test "round-trips every event type" do
      for type <- Kanban.Notifications.event_types() do
        token = UnsubscribeToken.sign(7, type)
        assert {:ok, %{user_id: 7, event_type: ^type}} = UnsubscribeToken.verify(token)
      end
    end

    test "rejects a tampered token" do
      token = UnsubscribeToken.sign(42, :review_requested)
      middle = div(byte_size(token), 2)
      <<head::binary-size(^middle), char, rest::binary>> = token
      flipped = if char == ?A, do: ?B, else: ?A

      assert {:error, :invalid} = UnsubscribeToken.verify(head <> <<flipped>> <> rest)
      assert {:error, :invalid} = UnsubscribeToken.verify(token <> "x")
    end

    test "rejects a token older than 90 days" do
      signed_at = System.system_time(:second) - @max_age - 1
      token = UnsubscribeToken.sign(42, :review_requested, signed_at: signed_at)

      assert {:error, :expired} = UnsubscribeToken.verify(token)
    end

    test "accepts a token just under 90 days old" do
      signed_at = System.system_time(:second) - @max_age + 60
      token = UnsubscribeToken.sign(42, :review_requested, signed_at: signed_at)

      assert {:ok, %{user_id: 42}} = UnsubscribeToken.verify(token)
    end

    test "rejects a token signed for another purpose" do
      token =
        Phoenix.Token.sign(KanbanWeb.Endpoint, "other-purpose", %{
          "user_id" => 42,
          "event_type" => "review_requested"
        })

      assert {:error, :invalid} = UnsubscribeToken.verify(token)
    end

    test "rejects a validly signed token naming an unknown event type" do
      token = UnsubscribeToken.sign(42, :not_a_type)

      assert {:error, :invalid} = UnsubscribeToken.verify(token)
    end

    test "rejects validly signed payloads of the wrong shape" do
      for payload <- [
            %{"user_id" => "42", "event_type" => "review_requested"},
            %{"user_id" => 42, "event_type" => :review_requested},
            %{"user_id" => 42},
            "not-a-map"
          ] do
        token = Phoenix.Token.sign(KanbanWeb.Endpoint, "notification-unsubscribe", payload)
        assert {:error, :invalid} = UnsubscribeToken.verify(token)
      end
    end

    test "rejects non-binary input" do
      assert {:error, :invalid} = UnsubscribeToken.verify(nil)
      assert {:error, :invalid} = UnsubscribeToken.verify(123)
    end
  end
end
