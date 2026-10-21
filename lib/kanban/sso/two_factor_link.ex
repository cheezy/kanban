defmodule Kanban.SSO.TwoFactorLink do
  @moduledoc """
  Finishes a single sign-on that stopped for the account's two-factor
  challenge (decided 2026-10-21).

  When single sign-on would link an existing account that has two-factor
  turned on, `Kanban.SSO.Provisioning` writes nothing, and the sign-in
  (`Kanban.SSO.OIDCLogin`, `Kanban.SSO.SAMLLogin`) returns a `link/2`: the
  connection's id and the subject the identity provider asserted. The
  controller keeps it in the pending-login marker
  (`KanbanWeb.TwoFactorPending`) and sends the person to the two-factor
  challenge. Once the account's code is accepted, `complete/3` reads the
  connection again (it must still be enabled), links the account
  (`Kanban.SSO.Provisioning.link_after_two_factor/3`), checks the paid gate,
  and records `:sso_login`, or `:sso_login_refused` with the reason.

  Later sign-ins find the linked identity and are not challenged again.
  """

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Repo
  alias Kanban.SSO
  alias Kanban.SSO.Provisioning
  alias Kanban.SSO.SSOConnection

  @type link :: %{connection_id: pos_integer(), subject: String.t()}

  @doc """
  The link a sign-in through `connection` waits to make, for the identity
  provider's `subject`.

      iex> Kanban.SSO.TwoFactorLink.link(%Kanban.SSO.SSOConnection{id: 3}, "abc")
      %{connection_id: 3, subject: "abc"}
  """
  @spec link(SSOConnection.t(), String.t()) :: link()
  def link(%SSOConnection{id: id}, subject) when is_integer(id) and is_binary(subject),
    do: %{connection_id: id, subject: subject}

  @doc """
  Links `user` to the identity in `link` after their two-factor code was
  accepted, and signs them in. `opts` takes `:ip` (recorded in the audit log
  only). Returns `{:ok, user}` or `{:error, reason}`.
  """
  @spec complete(User.t(), link(), keyword()) :: {:ok, User.t()} | {:error, atom()}
  def complete(%User{id: user_id}, %{connection_id: id, subject: subject}, opts)
      when is_list(opts) do
    case Repo.get_by(SSOConnection, id: id, enabled: true) do
      %SSOConnection{} = connection ->
        connection
        |> sign_in(subject, user_id)
        |> audit(connection, opts)

      nil ->
        AuditLog.event(:sso_login_refused,
          reason: :connection_unavailable,
          sso_connection_id: id,
          ip: opts[:ip]
        )

        {:error, :connection_unavailable}
    end
  end

  defp sign_in(connection, subject, user_id) do
    with {:ok, user, :linked} <- Provisioning.link_after_two_factor(connection, subject, user_id),
         :ok <- paid_access(user) do
      {:ok, user}
    end
  end

  defp paid_access(user) do
    case SSO.check_access(user, :controller) do
      :ok -> :ok
      {:error, {:plan_required, :sso}} -> {:error, :plan_required}
    end
  end

  # The audit calls name their action literally so the telemetry source scan
  # (test/kanban/telemetry/emit_sites_test.exs) finds them.
  defp audit({:ok, user}, connection, opts) do
    AuditLog.event(:sso_login,
      user_id: user.id,
      organization_id: connection.organization_id,
      sso_connection_id: connection.id,
      protocol: connection.protocol,
      ip: opts[:ip]
    )

    {:ok, user}
  end

  defp audit({:error, reason}, connection, opts) do
    AuditLog.event(:sso_login_refused,
      reason: reason,
      organization_id: connection.organization_id,
      sso_connection_id: connection.id,
      protocol: connection.protocol,
      ip: opts[:ip]
    )

    {:error, reason}
  end
end
