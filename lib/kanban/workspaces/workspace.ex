defmodule Kanban.Workspaces.Workspace do
  @moduledoc """
  A workspace: either personal or owned by an Organization.

  A personal workspace has `personal` true, no `organization_id` and exactly one
  owner row in `workspace_members`; it is never shown in the UI. An org
  workspace has `personal` false and an `organization_id`, and no owner row: the
  Organization owns it, and its org-admins manage it.

  `personal` and `organization_id` are never cast from caller params.
  `create_changeset/3` takes them as arguments the calling context has decided
  on, so a form field can never attach a workspace to another tenant. The
  database checks the combination (`workspaces_personal_iff_no_organization`)
  and refuses to flip `personal` later (`workspaces_personal_immutable`).

  ## Names

  Within one Organization no two unarchived, non-personal workspaces share a
  name, compared ignoring case (a product-owner decision, W2420). The partial
  unique index `workspaces_organization_id_lower_name_index` decides, so two
  org-admins creating the same name at the same moment cannot both succeed.
  `create_changeset/3` and `changeset/2` map it to "has already been taken" on
  `:name`. There is no earlier check in the changeset: the index is the only
  judge.

    * Archiving a workspace frees its name, because archived rows are outside
      the index.
    * Personal workspaces are outside the rule; every one is named "Personal".
    * Names are trimmed before they are compared.
    * Case folding is the database's `lower()`, which follows the database's
      character type. Under the C character type only ASCII letters fold, so
      "ÉCOLE" and "école" count as different names there.
    * No path unarchives a workspace today. One added later must save through a
      changeset carrying the same `unique_constraint`, because the index will
      refuse a name a live workspace already has.

  The migration that added the index renamed any duplicates already present:
  the oldest workspace kept its name and later ones got " (2)", " (3)" and so on.

  ## Slug

  The slug is generated on the server from the name plus a random suffix when
  the workspace is created, and is never regenerated, not even on a rename (a
  product-owner decision, W2420). This is intended: once a slug appears in a
  link it must stay a stable identifier, so after a rename it can stop
  resembling the name.

  There is no plan, seat or billing field. Whether a workspace is paid will be
  derived from its `organization_id` (by `Kanban.Plans`, planned in W2398), never
  stored here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Organizations.Organization
  alias Kanban.Workspaces.WorkspaceMember

  @type t :: %__MODULE__{}

  @name_max_length 100
  @slug_base_max_length 40
  @name_index :workspaces_organization_id_lower_name_index

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :personal, :boolean, default: false
    field :archived_at, :utc_datetime

    belongs_to :organization, Organization
    has_many :members, WorkspaceMember
    has_many :boards, Kanban.Boards.Board

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a new workspace.

  Only `:name` is cast from `attrs`. `personal` and `organization_id` are values
  the calling context has decided on. The changeset does not check that they
  agree; the database does, and a mismatch comes back as an error on
  `:personal`.
  """
  @spec create_changeset(map(), boolean(), integer() | nil) :: Ecto.Changeset.t()
  def create_changeset(attrs, personal, organization_id) when is_boolean(personal) do
    %__MODULE__{}
    |> cast(attrs, [:name])
    |> change(personal: personal, organization_id: organization_id)
    |> validate_name()
    |> put_slug()
    |> validate_required([:slug])
    |> unique_constraint(:slug)
    |> unique_constraint(:name, name: @name_index)
    |> foreign_key_constraint(:organization_id)
    |> check_constraint(:personal,
      name: :workspaces_personal_iff_no_organization,
      message: "a workspace is personal exactly when it has no organization"
    )
  end

  @doc """
  Builds a changeset that renames a workspace. Only `:name` is cast; the slug,
  `personal` and `organization_id` never change here. A name another live
  workspace in the same Organization already has, ignoring case, comes back as
  "has already been taken" on `:name` when the update is saved.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = workspace, attrs) do
    workspace
    |> cast(attrs, [:name])
    |> validate_name()
    |> unique_constraint(:name, name: @name_index)
  end

  @doc """
  Returns the slug base for `name`: accents folded to ASCII, lower case, runs of
  anything other than letters and digits collapsed to `-`, at most
  #{@slug_base_max_length} characters. A name with nothing left (for example one
  written only in a non-Latin script) gives `"workspace"`.
  """
  @spec slug_base(String.t()) :: String.t()
  def slug_base(name) when is_binary(name) do
    name
    |> fold_to_ascii()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, @slug_base_max_length)
    |> String.trim_trailing("-")
    |> case do
      "" -> "workspace"
      base -> base
    end
  end

  defp fold_to_ascii(name) do
    case :unicode.characters_to_nfd_binary(name) do
      decomposed when is_binary(decomposed) -> String.replace(decomposed, ~r/\p{Mn}/u, "")
      _invalid -> ""
    end
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &trim_name/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @name_max_length)
  end

  # Casting "" clears the name to nil (a whitespace-only name is cast as-is and
  # trimmed to "" here), which is a change on an existing workspace, so the
  # trim must let nil through for validate_required/2 to report it.
  defp trim_name(name) when is_binary(name), do: String.trim(name)
  defp trim_name(name), do: name

  # The random suffix keeps slugs unique across every workspace, including the
  # ones that may share a name: those in different Organizations, archived
  # ones and personal ones.
  defp put_slug(%Ecto.Changeset{valid?: true} = changeset) do
    name = get_field(changeset, :name)
    suffix = 5 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
    put_change(changeset, :slug, slug_base(name) <> "-" <> suffix)
  end

  defp put_slug(changeset), do: changeset
end
