defmodule Kanban.Reviews.ApprovalChallenge do
  @moduledoc """
  A one-time approval nonce (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.6, §7.5, §8).

  Issued by `POST /api/me/reviews/:task_id/approval_challenge` and signed by
  the device's approval key to approve that review. It is bound to the device,
  the task and the task's `review_requested_at` when it was issued, and to
  the submission itself through `review_fingerprint`, so work resubmitted
  inside the same second as the stamp it replaced is still a different
  submission. It lives 2 minutes and is used once: `used_at` is set when an
  approval consumes it.

  Like a device token, the plain nonce (prefix `sdan_`) is shown once in the
  virtual `nonce` field and only its SHA-256 hash is stored, so a nonce is
  never compared, logged or stored in plain text.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Tasks.Task

  @lifetime_seconds 120
  @prefix "sdan"
  @nonce_format ~r/\Asdan_[A-Za-z0-9_-]{43}\z/

  @type t :: %__MODULE__{}

  schema "approval_challenges" do
    field :nonce_hash, :string, redact: true
    field :nonce, :string, virtual: true, redact: true
    field :review_requested_at, :utc_datetime
    field :review_fingerprint, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :device, Device
    belongs_to :task, Task

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "How long a nonce lives, in seconds: #{@lifetime_seconds}."
  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds, do: @lifetime_seconds

  @doc """
  Whether `nonce` has the shape of an issued nonce: `sdan_` and 43
  characters of unpadded URL-safe base64.
  """
  @spec valid_nonce?(term()) :: boolean()
  def valid_nonce?(nonce) when is_binary(nonce), do: Regex.match?(@nonce_format, nonce)
  def valid_nonce?(_nonce), do: false

  # What a resubmission replaces: the completion the reviewer looked at.
  @fingerprint_fields [
    :completed_at,
    :completed_by_agent,
    :completion_summary,
    :completion_notes,
    :actual_files_changed,
    :changed_files,
    :review_report,
    :reviewer_result,
    :explorer_result
  ]

  @doc """
  A SHA-256 fingerprint, in lowercase hex, of the submission `task` carries:
  its completion fields (#{Enum.map_join(@fingerprint_fields, ", ", &"`#{&1}`")}).
  A resubmission replaces them, so it changes the fingerprint even when its
  `review_requested_at` falls in the same second as the one it replaced.
  """
  @spec review_fingerprint(Task.t()) :: String.t()
  def review_fingerprint(%Task{} = task) do
    task
    |> Map.take(@fingerprint_fields)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  A changeset for a new nonce for `device` and `task`, issued at `now` and
  expiring #{@lifetime_seconds} seconds later, bound to the task's current
  `review_requested_at` and submission fingerprint, with a fresh plain value in `nonce` and its hash in
  `nonce_hash`.
  """
  @spec create_changeset(Device.t(), Task.t(), DateTime.t()) :: Ecto.Changeset.t()
  def create_changeset(%Device{id: device_id}, %Task{} = task, %DateTime{} = now) do
    issued_at = DateTime.truncate(now, :second)
    plain = DeviceToken.generate(@prefix)

    %__MODULE__{device_id: device_id, task_id: task.id}
    |> change(%{
      review_requested_at: task.review_requested_at,
      review_fingerprint: review_fingerprint(task),
      expires_at: DateTime.add(issued_at, @lifetime_seconds, :second),
      inserted_at: issued_at
    })
    |> put_change(:nonce, plain)
    |> put_change(:nonce_hash, DeviceToken.hash_token(plain))
    |> unique_constraint(:nonce_hash)
  end
end
