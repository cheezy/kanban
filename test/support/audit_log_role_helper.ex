defmodule Kanban.AuditLogRoleHelper do
  @moduledoc """
  Sandbox helpers that run audit-log code as a non-superuser application role.

  Tests connect as a superuser, and a superuser bypasses every right
  `Kanban.AuditLog.Hardening` manages, so the separation between the
  application and the audit owner role can only be proven after switching to
  a role without superuser. Everything here runs inside the test's sandbox
  transaction: the throwaway role, its grants and the role switch all roll
  back when the test ends.

  The hardening statements lock `audit_events` until that rollback, so a test
  module using these helpers must be `async: false`.
  """

  alias Kanban.AuditLog.Hardening
  alias Kanban.Repo

  @doc "A `Kanban.AuditLog.Hardening` runner over the test repo."
  @spec runner() :: Hardening.runner()
  def runner, do: fn sql -> Repo.query!(sql) end

  @doc """
  Creates a uniquely named non-superuser role that stands in for the
  application role, and hardens `audit_events` for it with
  `Kanban.AuditLog.Hardening.apply/2`.

  Before hardening, the role is given every right on `audit_events` and on
  `users` — as a real application role has — so the
  hardening must strip the extra audit rights, and a test can delete a user as
  that role. Returns the role name. Must run while the connection is still the
  superuser.
  """
  @spec create_app_like_role() :: String.t()
  def create_app_like_role do
    name = unique_role_name("kanban_audit_test_")
    role = Hardening.quote_ident(name)

    Repo.query!("CREATE ROLE #{role} NOLOGIN")
    Repo.query!("GRANT ALL ON TABLE audit_events, users TO #{role}")
    :ok = Hardening.apply(runner(), app_role: name)
    name
  end

  @doc """
  A role name made of `prefix` and 16 random hex characters.

  Test partitions are separate VMs sharing one cluster, and role names are
  cluster-wide, so the suffix is random rather than a per-VM counter.
  """
  @spec unique_role_name(String.t()) :: String.t()
  def unique_role_name(prefix) do
    suffix = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    prefix <> suffix
  end

  @doc """
  Creates an app-like role with `create_app_like_role/0` and switches the
  sandbox transaction to it. Returns the role name.
  """
  @spec switch_to_app_like_role() :: String.t()
  def switch_to_app_like_role do
    name = create_app_like_role()
    switch_role(name)
    name
  end

  @doc "Switches the sandbox transaction to `name` until the test ends or `reset_role/0`."
  @spec switch_role(String.t()) :: :ok
  def switch_role(name) do
    Repo.query!("SET LOCAL ROLE #{Hardening.quote_ident(name)}")
    :ok
  end

  @doc "Switches the sandbox transaction back to the superuser it connected as."
  @spec reset_role() :: :ok
  def reset_role do
    Repo.query!("RESET ROLE")
    :ok
  end
end
