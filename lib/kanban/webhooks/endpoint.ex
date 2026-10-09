defmodule Kanban.Webhooks.Endpoint do
  @moduledoc """
  A board's outbound webhook endpoint (W2226): a generic receiver of signed
  JSON, or a Slack incoming webhook.

  The signing secret is stored only as `SecretBox` ciphertext in
  `encrypted_secret`, and the URL is stored encrypted too, through
  `Kanban.Integrations.EncryptedString`, because a Slack incoming-webhook URL
  is a credential: whoever holds it can post to the channel. Both are
  redacted from `inspect/1`. The virtual `secret` field carries the plaintext on the
  struct returned by a create or a rotation, so it can be shown once; a
  struct loaded from the database never has it. `board_id`, `created_by_id`
  and the secret are set by `Kanban.Webhooks`, never cast from params.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Integrations.EncryptedString
  alias Kanban.Integrations.SecretBox
  alias Kanban.Webhooks.UrlGuard

  @event_types ~w(
    task.created
    task.updated
    task.moved
    task.claimed
    task.unclaimed
    task.completed
    task.moved_to_review
    task.reviewed
    task.deleted
  )

  @kinds [:generic, :slack]

  schema "webhook_endpoints" do
    field :kind, Ecto.Enum, values: @kinds, default: :generic
    field :url, EncryptedString, redact: true
    field :encrypted_secret, :binary, redact: true
    field :secret, :string, virtual: true, redact: true
    field :event_types, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :lock_version, :integer, default: 1

    belongs_to :board, Kanban.Boards.Board
    belongs_to :created_by, Kanban.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The event names an endpoint can subscribe to."
  def event_types, do: @event_types

  @doc "The endpoint kinds."
  def kinds, do: @kinds

  @doc """
  Casts the owner-editable fields: `kind`, `url`, `event_types` and
  `enabled`. The URL gets `UrlGuard.validate_syntax/2` (no DNS); `opts` is
  passed through to it. At least one known event type is required.
  """
  def changeset(endpoint, attrs, opts \\ []) do
    endpoint
    |> cast(attrs, [:kind, :url, :event_types, :enabled])
    |> validate_required([:kind, :url, :enabled])
    |> validate_length(:url, max: 2048)
    |> update_change(:event_types, &Enum.uniq/1)
    |> validate_some_event_types()
    |> validate_subset(:event_types, @event_types)
    |> validate_url(opts)
  end

  # Checked on the field, not the change: casting [] onto the default [] is
  # no change at all, so validate_length/3 would never see it.
  defp validate_some_event_types(changeset) do
    case get_field(changeset, :event_types) do
      [_ | _] ->
        changeset

      _none ->
        add_error(changeset, :event_types, "should have at least %{count} item(s)",
          count: 1,
          validation: :length,
          kind: :min,
          type: :list
        )
    end
  end

  defp validate_url(changeset, opts) do
    validate_change(changeset, :url, fn :url, url ->
      case UrlGuard.validate_syntax(url, opts) do
        :ok -> []
        {:error, :too_long} -> []
        {:error, reason} -> [url: {UrlGuard.error_message(reason), reason: reason}]
      end
    end)
  end

  @doc """
  Generates a new signing secret, puts it on the virtual `secret` field and
  its ciphertext on `encrypted_secret`.
  """
  def put_new_secret(changeset) do
    secret = "whsec_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    changeset
    |> put_change(:secret, secret)
    |> put_change(:encrypted_secret, SecretBox.encrypt(secret))
  end
end
