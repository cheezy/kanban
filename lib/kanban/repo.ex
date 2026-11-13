defmodule Kanban.Repo do
  use Ecto.Repo,
    otp_app: :kanban,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Turns Ecto's own query logging off in every environment.
  `Kanban.Repo.QueryLogger` logs each query instead, from the
  `[:kanban, :repo, :query]` telemetry event, with the plaintext of encrypted
  fields redacted. The configured `:log` level, read from the application
  environment, still decides the level it logs at.
  """
  @impl true
  def init(_type, config), do: {:ok, Kanban.Repo.QueryLogger.disable_ecto_logging(config)}
end
