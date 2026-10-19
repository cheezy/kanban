defmodule KanbanWeb.Components.AccountStatus do
  @moduledoc """
  Chips that mark a disabled or unconfirmed account, for member lists.

  `account_status/1` renders **Disabled** for an account with `disabled_at`
  set and **Unconfirmed** for one that has never confirmed its email, and
  nothing for an enabled, confirmed account. The Organization member lists
  (`/admin/organizations/:id` and `/org`) show it beside each member, so staff
  and org-admins can see which accounts are not in working order before they
  rely on one to run the Organization.

  Colours are the measured status token pairs: `--st-blocked` on
  `--st-blocked-soft` (as the board members list's Disabled chip) and
  `--st-doing` on `--st-doing-soft`. Both are defined for light and dark mode
  inside `.stride-screen`, which `Layouts.app` provides.
  """
  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  @chip "font-size: 10.5px; font-weight: 600; padding: 1px 6px; border-radius: 4px; white-space: nowrap;"

  attr :user, :map, required: true, doc: "the member's user, with disabled_at and confirmed_at"
  attr :id_prefix, :string, default: "member", doc: "prefix for each chip's DOM id"

  def account_status(assigns) do
    ~H"""
    <span
      :if={@user.disabled_at}
      id={"#{@id_prefix}-disabled-#{@user.id}"}
      data-account-disabled
      title={gettext("This account is disabled and can't sign in.")}
      style={[chip(), "background: var(--st-blocked-soft); color: var(--st-blocked);"]}
    >
      {gettext("Disabled")}
    </span>
    <span
      :if={is_nil(@user.disabled_at) and is_nil(@user.confirmed_at)}
      id={"#{@id_prefix}-unconfirmed-#{@user.id}"}
      data-account-unconfirmed
      title={gettext("This account has not confirmed its email address yet.")}
      style={[chip(), "background: var(--st-doing-soft); color: var(--st-doing);"]}
    >
      {gettext("Unconfirmed")}
    </span>
    """
  end

  defp chip, do: @chip
end
