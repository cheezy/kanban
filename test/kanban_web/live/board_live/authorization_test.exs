defmodule KanbanWeb.BoardLive.AuthorizationTest do
  @moduledoc """
  Unit tests for the extracted board access-control helpers (W1447). The full
  LiveView flows (redirects, flashes, cross-board IDOR rejection) remain covered
  by show_test.exs; these pin the allow/deny decisions and their flash strings
  directly, since they are security controls.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.BoardLive.Authorization

  defp socket(assigns) do
    %{%Phoenix.LiveView.Socket{} | assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  describe "check_column_action_authorization/3" do
    test "rejects a non-owner managing columns" do
      assert Authorization.check_column_action_authorization(:new_column, :modify, %{
               ai_optimized_board: false
             }) == {:error, "Only the board owner can manage columns"}
    end

    test "rejects adding a column on an AI-optimized board even for the owner" do
      assert Authorization.check_column_action_authorization(:new_column, :owner, %{
               ai_optimized_board: true
             }) == {:error, "Cannot add columns to AI optimized boards"}
    end

    test "rejects editing a column on an AI-optimized board" do
      assert Authorization.check_column_action_authorization(:edit_column, :owner, %{
               ai_optimized_board: true
             }) == {:error, "Cannot edit columns on AI optimized boards"}
    end

    test "allows an owner on a normal board, and passes through unrelated actions" do
      assert Authorization.check_column_action_authorization(:new_column, :owner, %{
               ai_optimized_board: false
             }) == :ok

      assert Authorization.check_column_action_authorization(:index, :read, %{
               ai_optimized_board: false
             }) == :ok
    end
  end

  describe "check_new_column_authorization/3" do
    test "keeps manage_members owner-only (W1434 defense-in-depth)" do
      assert Authorization.check_new_column_authorization(:manage_members, :modify, %{}) ==
               {:error, "Only the board owner can manage board membership"}

      assert Authorization.check_new_column_authorization(:manage_members, :owner, %{}) == :ok
    end

    test "rejects a non-owner creating a column" do
      assert Authorization.check_new_column_authorization(:new_column, :modify, %{
               ai_optimized_board: false
             }) == {:error, "Only the board owner can create columns"}
    end
  end

  describe "authorization short-circuits on :can_modify" do
    test "authorize_move_task rejects a read-only user before touching the DB" do
      s = socket(%{can_modify: false})
      assert Authorization.authorize_move_task(s, "1", "2", "3") == {:error, :not_authorized}
    end

    test "authorize_modify_for_task rejects a read-only user before touching the DB" do
      s = socket(%{can_modify: false})
      assert Authorization.authorize_modify_for_task(s, "1") == {:error, :not_authorized}
    end
  end
end
