defmodule Kanban.Reviews.ApprovalChallenge do
  @moduledoc """
  A one-time approval nonce (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.6, §7.5, §8).

  Issued by `POST /api/me/reviews/:task_id/approval_challenge` and signed by
  the device's approval key to approve that review. It is bound to the device,
  the task and the task's `review_requested_at` when it was issued, and to
  what the reviewer was shown through `review_fingerprint`: the submission,
  so work resubmitted inside the same second as the stamp it replaced is
  still a different submission, and the task fields the review screen shows,
  so an edit to them after the challenge is not approved unseen. It lives
  2 minutes and is used once: `used_at` is set when an approval consumes it.

  Like a device token, the plain nonce (prefix `sdan_`) is shown once in the
  virtual `nonce` field and only its SHA-256 hash is stored, so a nonce is
  never compared, logged or stored in plain text.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Reviews.MobileReview
  alias Kanban.Tasks.Task

  @lifetime_seconds 120
  @prefix "sdan"
  @nonce_format ~r/\Asdan_[A-Za-z0-9_-]{43}\z/
  @fingerprint_format ~r/\A[0-9a-f]{64}\z/

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

  @doc """
  Whether `fingerprint` has the shape `review_fingerprint/1` returns: 64
  lowercase hexadecimal characters.
  """
  @spec valid_fingerprint?(term()) :: boolean()
  def valid_fingerprint?(fingerprint) when is_binary(fingerprint),
    do: Regex.match?(@fingerprint_format, fingerprint)

  def valid_fingerprint?(_fingerprint), do: false

  # What the reviewer was shown (design §7.5, decision 17 in §24).
  #
  # The task fields the review screen shows: the header's title, priority and
  # time spent, the task's own acceptance criteria and security considerations
  # (shown when the reviewer gave no structured verdict for them), and the
  # description, which the 2026-11-23 decision binds as well. An edit to any of
  # them after the challenge refuses the approval.
  #
  # Then what a resubmission replaces: the completion the reviewer looked at.
  #
  # Never a field that changes on unrelated writes (`updated_at`, `position`,
  # `column_id`), or every such write would void a live challenge.
  #
  # The section verdicts the screen shows are bound as well (see
  # `shown_verdicts/1`), since they are derived from more than these fields.
  @fingerprint_fields [
    :title,
    :description,
    :priority,
    :time_spent_minutes,
    :acceptance_criteria,
    :security_considerations,
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
  A SHA-256 fingerprint, in lowercase hex, of what the reviewer is shown for
  `task`: the task fields the review screen shows, the description, the
  completion fields of the submission
  (#{Enum.map_join(@fingerprint_fields, ", ", &"`#{&1}`")}), and the status
  of each section verdict the screen shows.

  The review screen's detail (`GET /api/me/reviews/:task_id`) returns it, and
  the app sends it back when it asks for a challenge, so an edit made after
  the screen loaded is refused before a nonce is issued. The challenge stores
  it, so an edit made after the challenge is refused at the approval.

  An edit to any of those fields changes the fingerprint. An edit to another
  field changes it only when it changes a section verdict's status, as
  clearing `testing_strategy`, `patterns_to_follow` or `pitfalls` can, and
  otherwise does not. A resubmission replaces the completion fields, so it
  changes the fingerprint even when its `review_requested_at` falls in the
  same second as the one it replaced. The fields are hashed exactly as
  stored, so a whitespace-only edit counts, and an edit reverted before the
  approval does not. The inputs are never logged.
  """
  @spec review_fingerprint(Task.t()) :: String.t()
  def review_fingerprint(%Task{} = task) do
    task
    |> Map.take(@fingerprint_fields)
    |> Map.put(:verdicts, shown_verdicts(task))
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The status of each section verdict the screen shows. Whether
  # `testing_strategy`, `patterns_to_follow` and `pitfalls` are present
  # decides between "passed" and "not_assessed" for a review that carries no
  # structured status, so the status is bound rather than those fields,
  # which the screen does not show.
  defp shown_verdicts(task),
    do: task |> MobileReview.verdicts() |> Enum.map(&{&1.section, &1.status})

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
