defmodule KanbanWeb.BoardLive.WebhookStateTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias Kanban.Webhooks.Endpoint
  alias KanbanWeb.BoardLive.WebhookState

  @disabled_creator %User{
    name: "Ada",
    email: "ada@example.com",
    disabled_at: ~U[2026-10-21 10:00:00Z]
  }

  defp endpoint(attrs), do: struct(%Endpoint{enabled: true, created_by: nil}, attrs)

  describe "added_by/1" do
    test "names the creator, falls back to their email, and marks a deleted account" do
      assert endpoint(created_by: %User{name: "Ada", email: "a@x"}) |> WebhookState.added_by() ==
               "Added by Ada"

      assert endpoint(created_by: %User{name: " ", email: "a@x"}) |> WebhookState.added_by() ==
               "Added by a@x"

      assert endpoint(created_by: nil) |> WebhookState.added_by() == "Added by a deleted account"
    end

    test "is nil when the creator was not preloaded" do
      assert WebhookState.added_by(%Endpoint{}) == nil
    end
  end

  describe "paused?/2" do
    test "only an enabled endpoint whose creator is not disabled is paused on a locked board" do
      assert endpoint([]) |> WebhookState.paused?(true)
      refute endpoint(enabled: false) |> WebhookState.paused?(true)
      refute endpoint(created_by: @disabled_creator) |> WebhookState.paused?(true)
    end

    test "nothing is paused on an unlocked board" do
      refute endpoint([]) |> WebhookState.paused?(false)
    end
  end

  describe "not_sending?/1" do
    test "is true only for an enabled endpoint whose creator is disabled" do
      assert endpoint(created_by: @disabled_creator) |> WebhookState.not_sending?()

      refute endpoint(enabled: false, created_by: @disabled_creator)
             |> WebhookState.not_sending?()

      refute endpoint([]) |> WebhookState.not_sending?()
    end
  end

  describe "note/2" do
    test "an endpoint switched off for its creator tells the owner to enable it" do
      lost = endpoint(enabled: false, disabled_reason: :creator_lost_access)

      assert WebhookState.note(lost, false) =~ "no longer has access to this board. Enable it"

      assert WebhookState.note(lost, true) =~
               "After this board moves into an Organization, enable it to take it over."
    end

    test "an endpoint the owner switched off has no note, locked or not" do
      assert endpoint(enabled: false) |> WebhookState.note(false) == nil
      assert endpoint(enabled: false) |> WebhookState.note(true) == nil
    end

    test "a disabled creator's endpoint says to disable and enable it, after the move when locked" do
      sending_nothing = endpoint(created_by: @disabled_creator)

      assert WebhookState.note(sending_nothing, false) =~ "is disabled. Disable and enable it"

      assert WebhookState.note(sending_nothing, true) =~
               "After this board moves into an Organization, disable and enable it"
    end

    test "a paused endpoint says it sends again after the move; an active one has no note" do
      assert endpoint([]) |> WebhookState.note(true) ==
               "Sends again once this board moves into an Organization."

      assert endpoint([]) |> WebhookState.note(false) == nil
    end
  end
end
