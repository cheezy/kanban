defmodule KanbanWeb.WorkspaceLive.TokensCard do
  @moduledoc """
  The Tokens section of `KanbanWeb.WorkspaceLive.Settings` (W2220): the form
  that creates a workspace-scoped API token, the new token's plain text shown
  once, and the list of the workspace's tokens with revoke.

  Rendered only for an org-admin of the workspace's Organization. The events
  it sends (`create_token`, `revoke_token`, `dismiss_token`) are handled, and
  re-authorized, by the settings LiveView.
  """
  use KanbanWeb, :html

  import KanbanWeb.UserLive.SettingsComponents, only: [settings_card: 1]

  alias Kanban.ApiTokens.ApiToken
  alias KanbanWeb.WorkspaceLive.Tokens

  attr :form, Phoenix.HTML.Form, required: true
  attr :tokens, :list, required: true
  attr :new_token, :string, default: nil

  def tokens_card(assigns) do
    ~H"""
    <.token_reveal :if={@new_token} token={@new_token} />

    <.settings_card
      id="tokens"
      tab={:tokens}
      title={gettext("Create a workspace token")}
      hint={
        gettext(
          "One token for every board in this workspace. It acts as you, reaches the AI Optimized boards you can modify, and names its board on each request with the X-Stride-Board header. It expires in 90 days."
        )
      }
    >
      <.form
        for={@form}
        id="workspace-token-form"
        phx-submit="create_token"
        class="flex flex-col gap-1"
      >
        <div class="grid grid-cols-1 gap-x-4 @md:grid-cols-2">
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Token name")}
            maxlength={ApiToken.max_text_length()}
            required
          />
          <.input
            field={@form[:agent_capabilities]}
            name="token[agent_capabilities]"
            value={capabilities_value(@form[:agent_capabilities].value)}
            type="text"
            label={gettext("Agent capabilities (comma-separated, optional)")}
          />
        </div>
        <div>
          <.button
            id="create-workspace-token"
            type="submit"
            variant="primary"
            class="btn btn-primary btn-sm"
            phx-disable-with={gettext("Creating...")}
          >
            {gettext("Create token")}
          </.button>
        </div>
      </.form>
    </.settings_card>

    <.settings_card
      id="workspace-token-list"
      title={gettext("Workspace tokens")}
      hint={
        gettext(
          "A token stops working when it is revoked, when it expires, or when the org-admin it acts as leaves this workspace or the Organization."
        )
      }
      compact
    >
      <p
        :if={@tokens == []}
        id="no-workspace-tokens"
        style="margin: 0; padding: 10px 0; font-size: 13px; color: var(--ink-2);"
      >
        {gettext("No workspace tokens yet.")}
      </p>
      <ul id="workspace-tokens" style="list-style: none; margin: 0; padding: 0;">
        <li
          :for={token <- @tokens}
          id={"workspace-token-#{token.id}"}
          class="flex flex-col gap-2 @md:flex-row @md:items-center @md:gap-4"
          style="padding: 10px 0; border-bottom: 1px solid var(--line);"
        >
          <span
            class="@md:flex-1 min-w-0"
            style="font-size: 13px; font-weight: 500; color: var(--ink); overflow-wrap: anywhere;"
          >
            {token.name}
          </span>
          <span
            class="@md:flex-1 min-w-0"
            style="font-size: 12.5px; color: var(--ink-2); overflow-wrap: anywhere;"
          >
            {token_details(token)}
          </span>
          <span
            id={"workspace-token-status-#{token.id}"}
            class="@md:w-24 @md:flex-shrink-0"
            style="font-size: 12px; font-family: var(--font-mono); color: var(--ink-2);"
          >
            {status_label(Tokens.status(token))}
          </span>
          <div class="flex flex-wrap items-center gap-2 @md:flex-shrink-0 @md:w-20">
            <.button
              :if={Tokens.status(token) == :active}
              id={"revoke-workspace-token-#{token.id}"}
              type="button"
              phx-click="revoke_token"
              phx-value-id={token.id}
              data-confirm={gettext("Revoke this token? Agents using it lose access immediately.")}
              class="btn btn-soft btn-sm"
            >
              {gettext("Revoke")}
            </.button>
          </div>
        </li>
      </ul>
    </.settings_card>
    """
  end

  attr :token, :string, required: true

  # The plain text, shown once after a create, with a copy button and a
  # dismiss button. It is never re-derived from the database, so it is gone
  # after a dismiss, a section change or a reload.
  defp token_reveal(assigns) do
    ~H"""
    <section
      id="workspace-token-reveal"
      style={[
        "background: var(--stride-orange-soft); border: 1px solid var(--line);",
        "border-radius: 10px; padding: 14px 16px;",
        "display: flex; align-items: flex-start; gap: 12px;"
      ]}
    >
      <span style="color: var(--stride-orange-ink); display: inline-flex; margin-top: 2px;">
        <.icon name="hero-key" class="w-5 h-5" />
      </span>
      <div style="flex: 1; min-width: 0;">
        <div style="font-size: 13px; font-weight: 600; color: var(--ink);">
          {gettext("Your new workspace token")}
        </div>
        <p style="margin: 4px 0 0; font-size: 11.5px; color: var(--ink-2); line-height: 1.5;">
          {gettext("Copy it now — you won't be able to see it again.")}
        </p>
        <div style="display: flex; align-items: center; gap: 8px; margin-top: 10px; flex-wrap: wrap;">
          <code
            id="workspace-token-value"
            style={[
              "flex: 1 1 220px; min-width: 0; padding: 6px 10px; border-radius: 5px;",
              "background: var(--surface); border: 1px solid var(--line-strong);",
              "color: var(--ink); font-family: var(--font-mono);",
              "font-size: 11.5px; word-break: break-all; user-select: all;"
            ]}
          >{@token}</code>
          <button
            id="workspace-token-copy"
            type="button"
            phx-click={
              JS.dispatch("stride:copy",
                to: "#workspace-token-value",
                detail: %{
                  copied: "workspace-token-copied",
                  failed: "workspace-token-copy-failed"
                }
              )
            }
            style={[
              "padding: 6px 12px; border-radius: 5px; border: none;",
              "background: var(--ink); color: var(--color-base-100);",
              "font-size: 12px; font-weight: 500; cursor: pointer;"
            ]}
          >
            {gettext("Copy")}
          </button>
          <span
            id="workspace-token-copied"
            role="status"
            style="display: none; font-size: 11.5px; color: var(--ink-2);"
          >
            {gettext("Copied!")}
          </span>
          <span
            id="workspace-token-copy-failed"
            role="status"
            style="display: none; font-size: 11.5px; color: var(--st-blocked);"
          >
            {gettext("Couldn't copy it. Select the token and copy it yourself.")}
          </span>
        </div>
      </div>
      <button
        id="workspace-token-dismiss"
        type="button"
        phx-click="dismiss_token"
        aria-label={gettext("Dismiss")}
        style="padding: 4px; border-radius: 4px; border: none; background: transparent; cursor: pointer; color: var(--ink-3);"
      >
        <.icon name="hero-x-mark" class="w-4 h-4" />
      </button>
    </section>
    """
  end

  defp capabilities_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp capabilities_value(value) when is_binary(value), do: value
  defp capabilities_value(_value), do: ""

  defp token_details(%ApiToken{} = token) do
    gettext("By %{creator} · created %{created} · last used %{used} · expires %{expires}",
      creator: creator(token),
      created: date(token.inserted_at),
      used: date(token.last_used_at),
      expires: date(token.expires_at)
    )
  end

  defp creator(%ApiToken{user: %{name: name}}) when is_binary(name) and name != "", do: name
  defp creator(%ApiToken{user: %{email: email}}) when is_binary(email), do: email
  defp creator(_token), do: "—"

  defp date(nil), do: gettext("never")
  defp date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")

  defp status_label(:active), do: gettext("Active")
  defp status_label(:revoked), do: gettext("Revoked")
  defp status_label(:expired), do: gettext("Expired")
end
