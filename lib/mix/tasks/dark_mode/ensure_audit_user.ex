defmodule Mix.Tasks.DarkMode.EnsureAuditUser do
  @shortdoc "Idempotently provisions a dedicated user for the dark-mode auditor"

  @moduledoc """
  Creates the `dark-mode-audit@stride.local` user (password
  `DarkMode!AuditUser123` — long enough to satisfy the registration
  changeset) and makes them an admin so the Playwright contrast auditor
  can log in and visit every authenticated route.

  Re-running the task is a no-op when the user already exists; safe to
  run as part of dev-environment setup.

  ## Usage

      mix dark_mode.ensure_audit_user

  This task is only meant for the local dev database. In production,
  the `:dev`/`:test` Mix env guard prevents accidental invocation.
  """
  use Mix.Task

  @audit_email "dark-mode-audit@stride.local"
  @audit_password "DarkMode!AuditUser123"

  @impl Mix.Task
  def run(_args) do
    guard_env!()
    Mix.Task.run("app.start")
    report(ensure_user())
  end

  defp guard_env! do
    unless Mix.env() in [:dev, :test] do
      Mix.shell().error("dark_mode.ensure_audit_user only runs in :dev or :test Mix env.")
      exit({:shutdown, 1})
    end
  end

  defp report({:ok, user}) do
    Mix.shell().info("dark_mode audit user ready: #{@audit_email}")
    Mix.shell().info("user_id=#{user.id} type=#{user.type}")
    :ok
  end

  defp report({:error, changeset}) do
    Mix.shell().error("Failed to provision audit user:")
    changeset.errors |> inspect() |> Mix.shell().error()
    exit({:shutdown, 1})
  end

  defp ensure_user do
    case Kanban.Accounts.get_user_by_email(@audit_email) do
      nil -> create_user()
      user -> promote_to_admin(user)
    end
  end

  defp create_user do
    with {:ok, user} <- register(),
         {:ok, _confirmed} <- confirm(user) do
      promote_to_admin(user)
    end
  end

  defp register do
    Kanban.Accounts.register_user(%{
      "email" => @audit_email,
      "password" => @audit_password
    })
  end

  defp confirm(user) do
    # The standard registration flow requires email confirmation before login.
    # In dev we shortcut by setting confirmed_at directly so the auditor can
    # sign in immediately.
    import Ecto.Query

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    query = from(u in Kanban.Accounts.User, where: u.id == ^user.id)
    {1, _} = Kanban.Repo.update_all(query, set: [confirmed_at: now])

    {:ok, user}
  end

  defp promote_to_admin(%{type: :admin} = user), do: {:ok, user}

  defp promote_to_admin(user) do
    Kanban.Accounts.update_user_type(user, :admin)
  end
end
