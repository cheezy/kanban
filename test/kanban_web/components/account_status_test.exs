defmodule KanbanWeb.Components.AccountStatusTest do
  @moduledoc """
  Tests for `KanbanWeb.Components.AccountStatus.account_status/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.Components.AccountStatus

  defp user(overrides) do
    Map.merge(%{id: 42, disabled_at: nil, confirmed_at: ~U[2026-10-01 00:00:00Z]}, overrides)
  end

  defp render_status(user, opts \\ []) do
    render_component(&AccountStatus.account_status/1, Keyword.put(opts, :user, user))
  end

  test "renders nothing for an enabled, confirmed account" do
    assert render_status(user(%{})) |> String.trim() == ""
  end

  test "renders Disabled, with a tooltip and the blocked token pair, for a disabled account" do
    html = render_status(user(%{disabled_at: ~U[2026-10-02 00:00:00Z]}))

    assert html =~ ~s(id="member-disabled-42")
    assert html =~ "data-account-disabled"
    assert html =~ "Disabled"
    assert html =~ "disabled and can&#39;t sign in"
    assert html =~ "var(--st-blocked-soft)"
    refute html =~ "Unconfirmed"
  end

  test "renders Unconfirmed, with the doing token pair, for an enabled unconfirmed account" do
    html = render_status(user(%{confirmed_at: nil}))

    assert html =~ ~s(id="member-unconfirmed-42")
    assert html =~ "data-account-unconfirmed"
    assert html =~ "Unconfirmed"
    assert html =~ "var(--st-doing-soft)"
    refute html =~ "Disabled"
  end

  test "a disabled account that never confirmed shows Disabled only" do
    html = render_status(user(%{disabled_at: ~U[2026-10-02 00:00:00Z], confirmed_at: nil}))

    assert html =~ "Disabled"
    refute html =~ "Unconfirmed"
  end

  test "prefixes the chip ids with id_prefix" do
    html = render_status(user(%{confirmed_at: nil}), id_prefix: "row")

    assert html =~ ~s(id="row-unconfirmed-42")
  end
end
