defmodule Mix.Tasks.DarkMode.EnsureAuditUser do
  @shortdoc "Idempotently provisions a dedicated user for the dark-mode auditor"

  @moduledoc """
  Creates the dark-mode audit user (default email
  `dark-mode-audit@stride.local`) and makes them an admin so the Playwright
  contrast auditor can log in and visit every authenticated route.

  The password is NOT hardcoded — it is read from the `STRIDE_AUDIT_PASSWORD`
  environment variable and the task fails fast if it is unset (W1435). Set the
  same variable for the Playwright auditor (`tools/dark-mode-audit/audit.mjs`)
  so both sides agree. The email can be overridden with `STRIDE_AUDIT_EMAIL`.

  Re-running the task is a no-op when the user already exists; safe to
  run as part of dev-environment setup.

  ## Usage

      STRIDE_AUDIT_PASSWORD=... mix dark_mode.ensure_audit_user

  This task is only meant for the local dev database. In production,
  the `:dev`/`:test` Mix env guard prevents accidental invocation.
  """
  use Mix.Task

  @default_audit_email "dark-mode-audit@stride.local"

  @impl Mix.Task
  def run(_args) do
    guard_env!()

    case resolve_audit_password() do
      {:ok, password} ->
        Mix.Task.run("app.start")
        report(ensure_user(password))

      {:error, :missing_password} ->
        Mix.shell().error(
          "STRIDE_AUDIT_PASSWORD must be set to provision the dark-mode audit user."
        )

        exit({:shutdown, 1})
    end
  end

  @doc """
  Resolves the audit user's password from `STRIDE_AUDIT_PASSWORD`.

  Returns `{:ok, password}` when the variable is set to a non-empty value, or
  `{:error, :missing_password}` otherwise. The password is never defaulted to a
  committed literal (W1435).
  """
  def resolve_audit_password do
    case System.get_env("STRIDE_AUDIT_PASSWORD") do
      password when is_binary(password) and password != "" -> {:ok, password}
      _ -> {:error, :missing_password}
    end
  end

  @doc """
  Resolves the audit user's email from `STRIDE_AUDIT_EMAIL`, falling back to the
  default (the email is not a secret, so a default is acceptable).
  """
  def audit_email do
    case System.get_env("STRIDE_AUDIT_EMAIL") do
      email when is_binary(email) and email != "" -> email
      _ -> @default_audit_email
    end
  end

  defp guard_env! do
    unless Mix.env() in [:dev, :test] do
      Mix.shell().error("dark_mode.ensure_audit_user only runs in :dev or :test Mix env.")
      exit({:shutdown, 1})
    end
  end

  defp report({:ok, user}) do
    Mix.shell().info("dark_mode audit user ready: #{audit_email()}")
    Mix.shell().info("user_id=#{user.id} type=#{user.type}")
    :ok
  end

  defp report({:error, changeset}) do
    Mix.shell().error("Failed to provision audit user:")
    changeset.errors |> inspect() |> Mix.shell().error()
    exit({:shutdown, 1})
  end

  defp ensure_user(password) do
    case Kanban.Accounts.get_user_by_email(audit_email()) do
      nil -> create_user(password)
      user -> promote_to_admin(user)
    end
  end

  defp create_user(password) do
    with {:ok, user} <- register(password),
         {:ok, _confirmed} <- confirm(user) do
      promote_to_admin(user)
    end
  end

  defp register(password) do
    Kanban.Accounts.register_user(%{
      "email" => audit_email(),
      "password" => password
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
