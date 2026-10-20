defmodule Kanban.Workspaces.Export.WorkspaceExport do
  @moduledoc """
  One requested export of an Organization workspace (W2222).

  `status` moves `"pending"` -> `"running"` -> `"succeeded"` or `"failed"`,
  and a succeeded export becomes `"expired"` once
  `Kanban.Workspaces.Export.CleanupWorker` deletes its file. `file_path` is
  written only by the export worker, under the configured export directory,
  and is never taken from a request. `error` holds one of `error_codes/0`,
  never a message or a path.

  The database allows at most one pending or running export per workspace
  (`workspace_exports_one_active_index`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(pending running succeeded failed expired)
  @error_codes ~w(storage_unavailable workspace_unavailable export_failed timed_out)

  @type t :: %__MODULE__{}

  schema "workspace_exports" do
    field :status, :string, default: "pending"
    field :file_path, :string
    field :byte_size, :integer
    field :expires_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :error, :string

    belongs_to :workspace, Kanban.Workspaces.Workspace
    belongs_to :requested_by, Kanban.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Every status an export can have."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Every error code a failed export can carry."
  @spec error_codes() :: [String.t()]
  def error_codes, do: @error_codes

  @doc """
  A pending export of the workspace with `workspace_id`, requested by the user
  with `requested_by_id`. Nothing is cast. A second pending or running export
  of the same workspace comes back as an error on `:workspace_id`.
  """
  @spec create_changeset(integer(), integer()) :: Ecto.Changeset.t()
  def create_changeset(workspace_id, requested_by_id) do
    %__MODULE__{}
    |> change(workspace_id: workspace_id, requested_by_id: requested_by_id, status: "pending")
    |> validate_required([:workspace_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:requested_by_id)
    |> unique_constraint(:workspace_id,
      name: :workspace_exports_one_active_index,
      message: "an export is already in progress"
    )
    |> check_constraint(:status, name: :workspace_exports_status_check)
  end

  @doc """
  Moves an export to a new state. Only the worker-written fields are cast, and
  `error` must be one of `error_codes/0`.
  """
  @spec transition_changeset(t(), map()) :: Ecto.Changeset.t()
  def transition_changeset(%__MODULE__{} = export, attrs) do
    export
    |> cast(attrs, [:status, :file_path, :byte_size, :expires_at, :completed_at, :error])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:error, @error_codes)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> check_constraint(:status, name: :workspace_exports_status_check)
  end
end
