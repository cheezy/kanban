defmodule Kanban.Organizations.Organization do
  @moduledoc """
  A paying Organization: its name, postal address and contact.

  Only an enabled site admin creates or edits one, through
  `Kanban.Organizations`. The contact name, phone and email are personal
  data, so they never appear in telemetry or log metadata, and they are
  redacted from `inspect/1` (and so from crash reports and changeset logs).

  `org_admin_count` and `member_count` are virtual. They are filled only by
  `Kanban.Organizations.list_organizations/1` and are `nil` everywhere else.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.ChangesetText
  alias Kanban.Organizations.OrganizationMember

  @type t :: %__MODULE__{}

  # Longest value each text field accepts. A longer value is rejected, never
  # truncated.
  @max_lengths [
    name: 160,
    address_line1: 200,
    address_line2: 200,
    city: 100,
    region: 100,
    postal_code: 20,
    country: 100,
    contact_name: 160,
    contact_phone: 40,
    contact_email: 160
  ]

  @fields Keyword.keys(@max_lengths)
  @contact_fields [:contact_name, :contact_phone, :contact_email]
  @required_fields [:name, :contact_name, :contact_email]

  schema "organizations" do
    field :name, :string
    field :address_line1, :string
    field :address_line2, :string
    field :city, :string
    field :region, :string
    field :postal_code, :string
    field :country, :string
    field :contact_name, :string, redact: true
    field :contact_phone, :string, redact: true
    field :contact_email, :string, redact: true

    field :org_admin_count, :integer, virtual: true
    field :member_count, :integer, virtual: true

    has_many :members, OrganizationMember

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or editing an Organization.

  Requires `name`, `contact_name` and `contact_email`, trims surrounding
  whitespace from every field, checks the email's format and rejects any
  value longer than its field's cap.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = organization, attrs) do
    organization
    |> cast(attrs, @fields)
    |> ChangesetText.validate_storable(@fields)
    |> trim_fields()
    |> validate_required(@required_fields)
    |> validate_format(:contact_email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_lengths()
  end

  @doc """
  Returns the contact fields, which hold personal data.
  """
  @spec contact_fields() :: [atom()]
  def contact_fields, do: @contact_fields

  @doc """
  Returns the longest value each text field accepts.
  """
  @spec max_lengths() :: keyword(pos_integer())
  def max_lengths, do: @max_lengths

  # A value that is only whitespace becomes nil, so a required field filled
  # with spaces is reported as missing.
  defp trim_fields(changeset) do
    Enum.reduce(@fields, changeset, fn field, acc ->
      update_change(acc, field, &trim/1)
    end)
  end

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(value), do: value

  defp validate_lengths(changeset) do
    Enum.reduce(@max_lengths, changeset, fn {field, max}, acc ->
      validate_length(acc, field, max: max)
    end)
  end
end
