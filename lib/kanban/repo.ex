defmodule Kanban.Repo do
  use Ecto.Repo,
    otp_app: :kanban,
    adapter: Ecto.Adapters.Postgres

  alias Kanban.Repo.ChangesetRedactor

  # The bang functions below re-raise Ecto.InvalidChangesetError with the
  # plaintext of encrypted fields redacted; see Kanban.Repo.ChangesetRedactor.
  defoverridable insert!: 1,
                 insert!: 2,
                 update!: 1,
                 update!: 2,
                 insert_or_update!: 1,
                 insert_or_update!: 2,
                 delete!: 1,
                 delete!: 2

  @doc """
  Turns Ecto's own query logging off in every environment.
  `Kanban.Repo.QueryLogger` logs each query instead, from the
  `[:kanban, :repo, :query]` telemetry event, with the plaintext of encrypted
  fields redacted. The configured `:log` level, read from the application
  environment, still decides the level it logs at.
  """
  @impl true
  def init(_type, config), do: {:ok, Kanban.Repo.QueryLogger.disable_ecto_logging(config)}

  @doc """
  `Ecto.Repo.insert!/2`, except that an `Ecto.InvalidChangesetError` it raises
  carries no plaintext encrypted value (`Kanban.Repo.ChangesetRedactor`).
  """
  @impl true
  def insert!(struct_or_changeset, opts \\ []) do
    super(struct_or_changeset, opts)
  rescue
    error in Ecto.InvalidChangesetError ->
      reraise ChangesetRedactor.redact_error(error), __STACKTRACE__
  end

  @doc """
  `Ecto.Repo.update!/2`, except that an `Ecto.InvalidChangesetError` it raises
  carries no plaintext encrypted value (`Kanban.Repo.ChangesetRedactor`).
  """
  @impl true
  def update!(changeset, opts \\ []) do
    super(changeset, opts)
  rescue
    error in Ecto.InvalidChangesetError ->
      reraise ChangesetRedactor.redact_error(error), __STACKTRACE__
  end

  @doc """
  `Ecto.Repo.insert_or_update!/2`, except that an `Ecto.InvalidChangesetError`
  it raises carries no plaintext encrypted value
  (`Kanban.Repo.ChangesetRedactor`).
  """
  @impl true
  def insert_or_update!(changeset, opts \\ []) do
    super(changeset, opts)
  rescue
    error in Ecto.InvalidChangesetError ->
      reraise ChangesetRedactor.redact_error(error), __STACKTRACE__
  end

  @doc """
  `Ecto.Repo.delete!/2`, except that an `Ecto.InvalidChangesetError` it raises
  carries no plaintext encrypted value (`Kanban.Repo.ChangesetRedactor`).
  """
  @impl true
  def delete!(struct_or_changeset, opts \\ []) do
    super(struct_or_changeset, opts)
  rescue
    error in Ecto.InvalidChangesetError ->
      reraise ChangesetRedactor.redact_error(error), __STACKTRACE__
  end
end
