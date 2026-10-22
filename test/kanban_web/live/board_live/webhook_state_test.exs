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
      assert WebhookState.added_by(endpoint(created_by: %User{name: "Ada", email: "a@x"})) ==
               "Added by Ada"

      assert WebhookState.added_by(endpoint(created_by: %User{name: " ", email: "a@x"})) ==
               "Added by a@x"

      assert WebhookState.added_by(endpoint(created_by: nil)) == "Added by a deleted account"
    end

    test "is nil when the creator was not preloaded" do
      assert WebhookState.added_by(%Endpoint{}) == nil
    end
  end

  describe "paused?/2" do
    test "only an enabled endpoint whose creator is not disabled is paused on a locked board" do
      assert WebhookState.paused?(endpoint([]), true)
      refute WebhookState.paused?(endpoint(enabled: false), true)
      refute WebhookState.paused?(endpoint(created_by: @disabled_creator), true)
    end

    test "nothing is paused on an unlocked board" do
      refute WebhookState.paused?(endpoint([]), false)
    end
  end

  describe "not_sending?/1" do
    test "is true only for an enabled endpoint whose creator is disabled" do
      assert WebhookState.not_sending?(endpoint(created_by: @disabled_creator))
      refute WebhookState.not_sending?(endpoint(enabled: false, created_by: @disabled_creator))
      refute WebhookState.not_sending?(endpoint([]))
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
      assert WebhookState.note(endpoint(enabled: false), false) == nil
      assert WebhookState.note(endpoint(enabled: false), true) == nil
    end

    test "a disabled creator's endpoint says to disable and enable it, after the move when locked" do
      sending_nothing = endpoint(created_by: @disabled_creator)

      assert WebhookState.note(sending_nothing, false) =~ "is disabled. Disable and enable it"

      assert WebhookState.note(sending_nothing, true) =~
               "After this board moves into an Organization, disable and enable it"
    end

    test "a paused endpoint says it sends again after the move; an active one has no note" do
      assert WebhookState.note(endpoint([]), true) ==
               "Sends again once this board moves into an Organization."

      assert WebhookState.note(endpoint([]), false) == nil
    end
  end
end
