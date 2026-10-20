defmodule Kanban.Workspaces.Invitation do
  @moduledoc """
  An email invitation to an Organization workspace or to a free board (W2219).

  Two kinds share this schema:

    * A **workspace invitation** has a `role` (`:member` or `:guest`) on an org
      workspace, and may also carry a board grant (`board_id` plus
      `board_access`) on a board in that workspace. Accepting it adds the
      invitee to the workspace's Organization.
    * A **board-only invitation** has no `role`. Its workspace is the inviting
      owner's personal workspace and it carries a board grant on a free board.
      Accepting it grants board access only.

  The token is treated like a password reset token: only its SHA-256 hash is
  stored (`token_hash`), the plaintext appears only in the email, and it
  expires after 7 days. Nothing that decides who may join — the workspace,
  board, inviter, token hash or expiry — is cast from caller params; the
  context passes them in.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Workspaces.Workspace

  @validity_days 7
  @rand_size 32
  @hash_algorithm :sha256
  # A url-encoded 32-byte token is 43 characters; anything far longer is not
  # one of ours and is refused before it is decoded.
  @max_token_length 64
  @email_format ~r/^[^@,;\s]+@[^@,;\s]+$/

  @type t :: %__MODULE__{}

  schema "workspace_invitations" do
    field :email, :string
    field :role, Ecto.Enum, values: [:member, :guest]
    field :board_access, Ecto.Enum, values: [:read_only, :modify]
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :workspace, Workspace
    belongs_to :board, Board
    belongs_to :invited_by, User
    belongs_to :registered_user, User

    timestamps(type: :utc_datetime)
  end

  @doc "How many days an invitation link stays valid."
  @spec validity_days() :: pos_integer()
  def validity_days, do: @validity_days

  @doc """
  Builds a new token: `{encoded, hash}`. `encoded` goes into the email link
  and is never stored; `hash` is what the row keeps.
  """
  @spec build_token() :: {String.t(), binary()}
  def build_token do
    raw = :crypto.strong_rand_bytes(@rand_size)
    {Base.url_encode64(raw, padding: false), :crypto.hash(@hash_algorithm, raw)}
  end

  @doc """
  Returns `{:ok, hash}` for a token `build_token/0` could have produced, and
  `:error` for anything else (wrong type, too long, not url-safe base64, or
  not #{@rand_size} bytes once decoded).
  """
  @spec hash_token(term()) :: {:ok, binary()} | :error
  def hash_token(token) when is_binary(token) and byte_size(token) <= @max_token_length do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} when byte_size(raw) == @rand_size -> {:ok, :crypto.hash(@hash_algorithm, raw)}
      _invalid -> :error
    end
  end

  def hash_token(_token), do: :error

  @doc "The expiry for an invitation sent at `now`: #{@validity_days} days later."
  @spec expires_at_from(DateTime.t()) :: DateTime.t()
  def expires_at_from(%DateTime{} = now) do
    now |> DateTime.add(@validity_days, :day) |> DateTime.truncate(:second)
  end

  @doc "Trims and downcases an email so two spellings of one address compare equal."
  @spec normalize_email(term()) :: String.t() | nil
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(_email), do: nil

  @doc """
  Validates the invite form for a workspace invitation: `email` and `role`.
  Used both for `phx-change` feedback and, with `put_server_fields/2`, for
  the insert.
  """
  @spec workspace_changeset(map()) :: Ecto.Changeset.t()
  def workspace_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:email, :role])
    |> validate_email()
    |> validate_required([:role])
  end

  @doc """
  Validates a board invitation: `email` and `board_access` (`read_only` or
  `modify`; anything else, `owner` included, is invalid).
  """
  @spec board_changeset(map()) :: Ecto.Changeset.t()
  def board_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:email, :board_access])
    |> validate_email()
    |> validate_required([:board_access])
  end

  @doc """
  Puts the values the context decided on — workspace, board, inviter, token
  hash, expiry, and (for an org board invitation) a role — on a changeset
  from `workspace_changeset/1` or `board_changeset/1`, with the database
  constraints mapped to changeset errors.
  """
  @spec put_server_fields(Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def put_server_fields(%Ecto.Changeset{} = changeset, fields) do
    changeset
    |> change(
      Map.take(fields, [:workspace_id, :board_id, :invited_by_id, :token_hash, :expires_at])
    )
    |> maybe_put(:role, Map.get(fields, :role))
    |> maybe_put(:board_access, Map.get(fields, :board_access))
    |> validate_required([:workspace_id, :token_hash, :expires_at])
    |> invitation_constraints()
  end

  @doc """
  Renews a pending invitation for a resend or a repeated invite: a new token
  hash and expiry, and the latest inviter, role and board access.
  """
  @spec renew_changeset(t(), map()) :: Ecto.Changeset.t()
  def renew_changeset(%__MODULE__{} = invitation, fields) do
    invitation
    |> change(Map.take(fields, [:token_hash, :expires_at, :invited_by_id, :role, :board_access]))
    |> invitation_constraints()
  end

  @doc "Marks an invitation accepted at `now`."
  @spec accept_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def accept_changeset(%__MODULE__{} = invitation, now),
    do: change(invitation, accepted_at: DateTime.truncate(now, :second))

  @doc "Marks an invitation revoked at `now`."
  @spec revoke_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def revoke_changeset(%__MODULE__{} = invitation, now),
    do: change(invitation, revoked_at: DateTime.truncate(now, :second))

  @doc "Links an invitation to the account registered from its link."
  @spec register_changeset(t(), integer()) :: Ecto.Changeset.t()
  def register_changeset(%__MODULE__{} = invitation, user_id),
    do: change(invitation, registered_user_id: user_id)

  @doc "True when the invitation is neither accepted, revoked nor expired at `now`."
  @spec pending?(t(), DateTime.t()) :: boolean()
  def pending?(%__MODULE__{accepted_at: nil, revoked_at: nil, expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def pending?(%__MODULE__{}, _now), do: false

  @doc "True when `email` is the invited address, ignoring case and surrounding space."
  @spec email_matches?(t(), term()) :: boolean()
  def email_matches?(%__MODULE__{email: invited}, email) do
    normalized = normalize_email(email)
    is_binary(normalized) and normalized == normalize_email(invited)
  end

  @doc "Invitations that are neither accepted nor revoked (expiry not applied)."
  @spec open_query() :: Ecto.Query.t()
  def open_query do
    from(i in __MODULE__, where: is_nil(i.accepted_at) and is_nil(i.revoked_at))
  end

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_format(:email, @email_format, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
  end

  defp maybe_put(changeset, _field, nil), do: changeset
  defp maybe_put(changeset, field, value), do: put_change(changeset, field, value)

  defp invitation_constraints(changeset) do
    changeset
    |> unique_constraint(:token_hash)
    |> unique_constraint(:email,
      name: :workspace_invitations_one_pending_index,
      message: "already has a pending invitation"
    )
    |> check_constraint(:role, name: :workspace_invitations_grant_present)
    |> check_constraint(:role, name: :workspace_invitations_role_check)
    |> check_constraint(:board_access, name: :workspace_invitations_access_check)
    |> check_constraint(:board_access, name: :workspace_invitations_board_has_access)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:board_id)
  end
end
