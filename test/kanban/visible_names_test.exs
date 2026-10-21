defmodule Kanban.VisibleNamesTest do
  @moduledoc """
  Every required name refuses text with no visible character (decided
  2026-10-21, `Kanban.ChangesetText.validate_visible/2`): API token, board,
  column, label, delivery target and Organization names, and an
  Organization's contact name.
  """
  use ExUnit.Case, async: true

  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards.Board
  alias Kanban.Columns.Column
  alias Kanban.Labels.Label
  alias Kanban.Organizations.Organization
  alias Kanban.Targets.DeliveryTarget

  # Five zero-width spaces, so a board name also clears its 5-character minimum.
  @invisible String.duplicate(<<0x200B::utf8>>, 5)

  # Each changeset with valid attrs for everything but the field under test.
  defp cases(name), do: token_cases(name) ++ board_cases(name) ++ other_cases(name)

  defp token_cases(name) do
    [
      {"api token", :name,
       ApiToken.changeset(%ApiToken{}, %{name: name, user_id: 1, board_id: 1})},
      {"workspace token", :name,
       ApiToken.workspace_changeset(%ApiToken{}, %{name: name, user_id: 1, workspace_id: 1})}
    ]
  end

  defp board_cases(name) do
    [
      {"board", :name, Board.changeset(%Board{}, %{name: name})},
      {"board (owner)", :name, Board.owner_changeset(%Board{}, %{name: name})},
      {"column", :name, Column.changeset(%Column{}, %{name: name, position: 0})},
      {"label", :name, Label.changeset(%Label{}, %{name: name, color: hd(Label.colors())})}
    ]
  end

  defp other_cases(name) do
    org = %{name: "Acme", contact_name: "Ada", contact_email: "ada@example.com"}

    [
      {"delivery target", :name,
       DeliveryTarget.changeset(%DeliveryTarget{}, %{name: name, target_date: ~D[2026-12-01]})},
      {"organization", :name, Organization.changeset(%Organization{}, %{org | name: name})},
      {"organization contact", :contact_name,
       Organization.changeset(%Organization{}, %{org | contact_name: name})}
    ]
  end

  test "an invisible-only name is blank" do
    for {label, field, changeset} <- cases(@invisible) do
      assert {"can't be blank", _} = changeset.errors[field], label
    end
  end

  test "a name with a visible character passes the rule" do
    for {label, field, changeset} <- cases("Visible name") do
      assert changeset.errors[field] == nil, label
    end
  end
end
