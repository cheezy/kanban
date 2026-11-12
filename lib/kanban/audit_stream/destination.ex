defmodule Kanban.AuditStream.Destination do
  @moduledoc """
  A place one Organization streams its audit log to: a Splunk HTTP Event
  Collector, a Datadog logs intake, or a generic HTTPS endpoint
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §9.2).

  The four secret fields (`url`, `credential`, `signing_secret` and
  `previous_signing_secret`) are encrypted at rest with
  `Kanban.Encryption.TolerantEncryptedBinary` and redacted from inspection.
  A secret written under a lost or replaced `ENCRYPTION_KEY` loads as
  `:unreadable` rather than failing the row (D17); `unreadable_secrets/1`
  lists those fields. `settings` holds only non-secret values.

  The hints shown in place of secrets are derived here, from the plaintext:
  `url_host`, and the last 4 characters of the URL (`url_hint`) and of the
  credential (`credential_hint`). A credential shorter than 16 characters
  gets no hint, so a hint never shows a large share of a short credential.
  `url_hint` is the URL's own last 4 characters (§9.2), so a URL that ends in
  a token shows that token's last 4 characters; a URL is never shorter than
  16. A hint never splits a character made of several codepoints, so it can
  be shorter than 4. A URL must parse with a host of at most 253 characters
  (the DNS maximum), so `url_host` is set for every URL stored.

  Names are normalized before they are checked: NFC, with characters that
  render as nothing removed and surrounding whitespace trimmed, as
  `Kanban.Workspaces.Workspace` does, so two names that look the same are
  the same name for the uniqueness check.

  `excluded_actions` names audit actions never streamed. Every
  `audit_stream_` action is refused there, so changes to streaming stay
  visible to every destination (§12.3).

  `max_destinations/0` is the per-Organization limit set by
  `AUDIT_STREAM_MAX_DESTINATIONS` (`config/runtime.exs`), read at call time.

  `filter_version` is increased by the context whenever `excluded_actions` or
  `include_personal_data` changes (D16); the cursor lives in
  `Kanban.AuditStream.Cursor` so the worker's writes never conflict with an
  edit here (§9.3).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.ChangesetText
  alias Kanban.Encryption.TolerantEncryptedBinary
  alias Kanban.Organizations.Organization
  alias Kanban.Telemetry.Catalog

  @type t :: %__MODULE__{}

  @kinds [:splunk_hec, :datadog, :https]
  @states [:healthy, :retrying, :failing]
  @halted_reasons [:rejected_batch, :blocked_address, :txid_reset, :credentials_unreadable]
  @secret_fields [:url, :credential, :signing_secret, :previous_signing_secret]

  # The non-secret settings each kind may carry (§9.2). Their values are
  # checked here only at a generic level; each kind's own rules come with its
  # sender.
  @settings_keys %{
    splunk_hec: ~w(index source_type),
    datadog: ~w(site service tags),
    https: ~w(format header_name)
  }

  @list_settings ~w(tags)

  @reserved_prefix "audit_stream_"

  @default_max_destinations 3

  # A hint is the last 4 characters of a secret of at least 16.
  @hint_length 4
  @hint_min_length 16

  @max_host_length 253

  # Characters that render as nothing, removed from names: format characters
  # except the joiners some scripts and emoji need, and the invisible letters
  # Kanban.ChangesetText.visible?/1 lists. The same set as Workspace names.
  @invisible ~r/(?![\x{200C}\x{200D}])[\p{Cf}\x{034F}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{3164}\x{FFA0}]/u

  schema "audit_stream_destinations" do
    belongs_to :organization, Organization
    field :kind, Ecto.Enum, values: @kinds
    field :name, :string
    field :enabled, :boolean, default: true
    field :url, TolerantEncryptedBinary, redact: true
    field :url_host, :string
    field :url_hint, :string
    field :settings, :map, default: %{}
    field :credential, TolerantEncryptedBinary, redact: true
    field :credential_hint, :string
    field :signing_secret, TolerantEncryptedBinary, redact: true
    field :previous_signing_secret, TolerantEncryptedBinary, redact: true
    field :previous_secret_expires_at, :utc_datetime
    field :include_personal_data, :boolean, default: true
    field :excluded_actions, {:array, :string}, default: []
    field :filter_version, :integer, default: 1
    field :schema_version, :integer, default: 1
    field :state, Ecto.Enum, values: @states, default: :healthy
    field :state_reason, :string
    field :halted_reason, Ecto.Enum, values: @halted_reasons
    field :failing_since, :utc_datetime
    field :consecutive_failures, :integer, default: 0
    field :last_success_at, :utc_datetime
    field :failing_emailed_at, :utc_datetime
    field :recovered_emailed_at, :utc_datetime
    belongs_to :created_by, User
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  @doc "The destination kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The fields that hold an encrypted secret."
  @spec secret_fields() :: [atom()]
  def secret_fields, do: @secret_fields

  @doc "The values `halted_reason` accepts."
  @spec halted_reasons() :: [atom()]
  def halted_reasons, do: @halted_reasons

  @doc "The settings keys each kind may carry."
  @spec settings_keys() :: %{atom() => [String.t()]}
  def settings_keys, do: @settings_keys

  @doc """
  A changeset for the fields an org-admin edits. The Organization and
  `created_by` are set on the struct by the caller, never cast.

  Validates the kind, the name (at most 80 characters, unique in the
  Organization), the secrets each kind needs, the settings keys for the kind
  and `excluded_actions`, then derives `url_host`, `url_hint` and
  `credential_hint` from the plaintext.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = destination, attrs) do
    destination
    |> cast(attrs, [
      :kind,
      :name,
      :enabled,
      :url,
      :credential,
      :settings,
      :include_personal_data,
      :excluded_actions
    ])
    |> validate_text()
    |> validate_kind_secrets()
    |> validate_settings()
    |> validate_excluded_actions()
    |> validate_url()
    |> unique_constraint([:organization_id, :name], error_key: :name)
    |> foreign_key_constraint(:organization_id)
    |> put_hints()
  end

  @doc """
  A changeset for the delivery state the worker and context set: `state`,
  its reason, the halt reason and the failure and email timestamps.
  """
  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = destination, attrs) do
    destination
    |> cast(attrs, [
      :state,
      :state_reason,
      :halted_reason,
      :failing_since,
      :consecutive_failures,
      :last_success_at,
      :failing_emailed_at,
      :recovered_emailed_at
    ])
    |> ChangesetText.validate_storable([:state_reason])
    |> validate_required([:state])
    |> validate_length(:state_reason, max: 255, count: :codepoints)
    |> validate_number(:consecutive_failures, greater_than_or_equal_to: 0)
  end

  @doc """
  A changeset for the signing secrets, which the context generates and
  rotates.
  """
  @spec signing_secret_changeset(t(), map()) :: Ecto.Changeset.t()
  def signing_secret_changeset(%__MODULE__{} = destination, attrs) do
    cast(destination, attrs, [
      :signing_secret,
      :previous_signing_secret,
      :previous_secret_expires_at
    ])
  end

  @doc """
  The audit actions `excluded_actions` may name: every action in the
  `:audit` domain of `events` (the telemetry catalog's, by default) except
  the `audit_stream_` ones.
  """
  @spec excludable_actions([map()]) :: [String.t()]
  def excludable_actions(events \\ Catalog.events()) do
    events
    |> Enum.filter(&(&1.domain == :audit))
    |> Enum.map(&(&1.name |> List.last() |> Atom.to_string()))
    |> Enum.reject(&String.starts_with?(&1, @reserved_prefix))
  end

  @doc """
  The secret fields of a loaded destination whose ciphertext could not be
  decrypted, in `secret_fields/0` order. A field that is not set (`nil`) is
  never listed.
  """
  @spec unreadable_secrets(t()) :: [atom()]
  def unreadable_secrets(%__MODULE__{} = destination) do
    Enum.filter(@secret_fields, &(Map.fetch!(destination, &1) == :unreadable))
  end

  @doc """
  The most destinations one Organization may have: `AUDIT_STREAM_MAX_DESTINATIONS`
  when it is set, else 3. Read at call time.
  """
  @spec max_destinations() :: pos_integer()
  def max_destinations do
    :kanban
    |> Application.get_env(Kanban.AuditStream, [])
    |> Keyword.get(:max_destinations, @default_max_destinations)
  end

  defp validate_text(changeset) do
    changeset
    |> ChangesetText.validate_storable([:name, :url, :credential])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:kind, :name, :enabled, :include_personal_data])
    |> ChangesetText.validate_visible([:name])
    |> validate_length(:name, max: 80, count: :codepoints)
    |> validate_length(:url, max: 2048)
    |> validate_length(:credential, max: 4096)
  end

  # Datadog's intake URL comes from its site setting, so a Datadog
  # destination has no URL; the others need one. Splunk and Datadog
  # authenticate with a token or API key; an HTTPS endpoint may not.
  defp validate_kind_secrets(changeset) do
    case get_field(changeset, :kind) do
      :splunk_hec -> validate_required(changeset, [:url, :credential])
      :datadog -> changeset |> validate_required([:credential]) |> validate_no_url()
      :https -> validate_required(changeset, [:url])
      nil -> changeset
    end
  end

  defp validate_no_url(changeset) do
    case get_field(changeset, :url) do
      nil -> changeset
      _url -> add_error(changeset, :url, "is invalid", validation: :kind)
    end
  end

  # A name ChangesetText.validate_storable/2 refused is left as it is, and nil
  # is left for validate_required/3 to report.
  defp normalize_name(name) when is_binary(name) do
    if String.valid?(name) do
      name
      |> :unicode.characters_to_nfc_binary()
      |> String.replace(@invisible, "")
      |> String.trim()
    else
      name
    end
  end

  defp normalize_name(name), do: name

  defp validate_settings(changeset) do
    changeset
    |> update_change(:settings, &stringify_keys/1)
    |> validate_required([:settings])
    |> validate_settings_shape()
  end

  defp stringify_keys(settings) when is_map(settings),
    do: Map.new(settings, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(settings), do: settings

  defp validate_settings_shape(changeset) do
    allowed = Map.get(@settings_keys, get_field(changeset, :kind), [])
    settings = get_field(changeset, :settings) || %{}

    if Enum.all?(settings, &valid_setting?(&1, allowed)) do
      changeset
    else
      add_error(changeset, :settings, "is invalid", validation: :settings)
    end
  end

  defp valid_setting?({key, value}, allowed) do
    key in allowed and valid_setting_value?(key in @list_settings, value)
  end

  defp valid_setting_value?(true, values) when is_list(values),
    do: Enum.all?(values, &storable_string?/1)

  defp valid_setting_value?(false, value), do: storable_string?(value)
  defp valid_setting_value?(_list?, _value), do: false

  defp storable_string?(value), do: is_binary(value) and ChangesetText.storable?(value)

  defp validate_excluded_actions(changeset) do
    changeset
    |> update_change(:excluded_actions, &uniq_actions/1)
    |> validate_required([:excluded_actions])
    |> validate_change(:excluded_actions, fn :excluded_actions, actions ->
      if Enum.any?(actions, &reserved_action?/1) do
        [excluded_actions: {"has an invalid entry", validation: :audit_stream_action}]
      else
        []
      end
    end)
    |> validate_subset(:excluded_actions, excludable_actions())
  end

  defp uniq_actions(actions) when is_list(actions), do: Enum.uniq(actions)
  defp uniq_actions(actions), do: actions

  defp reserved_action?(action) when is_binary(action),
    do: String.starts_with?(action, @reserved_prefix)

  defp reserved_action?(_action), do: false

  # A stored URL always has a host, so url_host is never silently missing,
  # and the host fits the varchar(255) column: at most what DNS allows. Text
  # that is not valid UTF-8 is left to ChangesetText.validate_storable/2.
  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      cond do
        not String.valid?(url) ->
          []

        is_nil(url_host(url)) ->
          [url: {"is invalid", validation: :url}]

        byte_size(url_host(url)) > @max_host_length ->
          [url: {"is invalid", validation: :url_host}]

        true ->
          []
      end
    end)
  end

  defp put_hints(%Ecto.Changeset{valid?: true} = changeset) do
    changeset
    |> put_url_hints()
    |> put_credential_hint()
  end

  defp put_hints(changeset), do: changeset

  defp put_url_hints(changeset) do
    case fetch_change(changeset, :url) do
      {:ok, url} ->
        changeset
        |> put_change(:url_host, url_host(url))
        |> put_change(:url_hint, hint(url))

      :error ->
        changeset
    end
  end

  defp put_credential_hint(changeset) do
    case fetch_change(changeset, :credential) do
      {:ok, credential} -> put_change(changeset, :credential_hint, hint(credential))
      :error -> changeset
    end
  end

  defp url_host(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> String.downcase(host)
      _invalid -> nil
    end
  end

  defp url_host(nil), do: nil

  # The last whole characters of `value` that fit in 4 codepoints (the
  # varchar(4) column), never splitting a character made of several.
  defp hint(value) when is_binary(value) do
    if length(String.codepoints(value)) >= @hint_min_length do
      value |> String.graphemes() |> Enum.reverse() |> take_hint([], 0)
    end
  end

  defp hint(nil), do: nil

  defp take_hint([grapheme | rest], acc, size) do
    grapheme_size = length(String.codepoints(grapheme))

    if size + grapheme_size <= @hint_length,
      do: take_hint(rest, [grapheme | acc], size + grapheme_size),
      else: join_hint(acc)
  end

  defp take_hint([], acc, _size), do: join_hint(acc)

  defp join_hint([]), do: nil
  defp join_hint(graphemes), do: Enum.join(graphemes)
end
