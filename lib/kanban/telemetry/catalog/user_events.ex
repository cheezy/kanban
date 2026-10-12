defmodule Kanban.Telemetry.Catalog.UserEvents do
  @moduledoc """
  The account, session and user administration events in
  `Kanban.Telemetry.Catalog`.

  The account events are emitted by `Kanban.Accounts.UserTelemetry` once the
  change they report has been saved, so a refused, invalid or rolled-back
  change emits nothing. The two session events, `logged_out` and
  `sessions_revoked`, are emitted by `KanbanWeb.UserAuth`, next to the legacy
  `[:kanban, :user, :login]` event.

  Metadata carries ids and user types only. Email addresses (old or new),
  names, passwords and token values are never sent, because telemetry
  handlers may forward events to tools outside the app. The legacy
  `registration` and `login` entries stay in `Kanban.Telemetry.Catalog`
  itself. `Kanban.Telemetry.Catalog` appends these entries to its own list;
  nothing else should call this module.
  """

  @events [
    %{
      name: [:kanban, :user, :logged_out],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description:
        "A user signed out of the browser. user_id is absent when nobody was signed in.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :sessions_revoked],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description:
        "A user's open sessions were disconnected after a password change or reset. count is the number of tokens revoked and may be 0; user_id is absent when no token names the user.",
      legacy: false,
      metrics: [sum: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :password_changed],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description: "A signed-in user changed their password.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :password_reset_completed],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description: "A user set a new password through a password reset link.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :email_change_requested],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description:
        "A user asked to change their email address and a confirmation link was sent. Neither address is sent.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :email_changed],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description:
        "A user confirmed an email change and their address was updated. Neither address is sent.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :confirmed],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description: "A user confirmed their account.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :name_changed],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description: "A user changed their display name. The name itself is never sent.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :type_changed],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id, :from_type, :to_type],
      description:
        "A user's type changed, for example from :user to :admin. It carries no actor_user_id, because update_user_type/2 is not given one.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :disabled],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id, :actor_user_id],
      description:
        "An administrator disabled an enabled user. user_id is the user, actor_user_id the administrator.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :enabled],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id, :actor_user_id],
      description:
        "An administrator enabled a disabled user. user_id is the user, actor_user_id the administrator.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :deleted],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id, :actor_user_id],
      description:
        "An administrator deleted a user. user_id is the deleted user's id, actor_user_id the administrator.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    }
  ]

  @doc """
  Returns the account, session and user administration entries, in
  declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
