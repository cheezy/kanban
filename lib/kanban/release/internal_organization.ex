defmodule Kanban.Release.InternalOrganization do
  @moduledoc """
  Creates Stride's own internal Organization and appoints its org-admins, for
  `Kanban.Release.ensure_internal_organization/1` (W2403).

  The Organization list and every write go through `Kanban.Organizations` as
  the named acting site admin, so the context's authorization check, telemetry
  and audit events apply exactly as they do in the admin UI: shell access to the
  server does not skip them. Users are looked up by email through
  `Kanban.Accounts`, and the org-admin check before each appointment is
  `Kanban.Organizations.org_admin?/2`, which takes no actor. Nothing here
  provisions an account. An org-admin email with no account is reported back as
  skipped.

  Running it again changes nothing. An Organization whose name is exactly
  `name` (after trimming, compared case-sensitively) is reused, the lowest id
  first if there are several, and its details are left as they are. A listed
  user who is already an org-admin of it is reported, not written.

  It is kept apart from `Kanban.Release` so that module stays small; it calls
  no Mix function and prints nothing.
  """

  alias Ecto.Changeset
  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization

  @default_name "Stride"
  @organization_fields [
    :contact_name,
    :contact_email,
    :contact_phone,
    :address_line1,
    :address_line2,
    :city,
    :region,
    :postal_code,
    :country
  ]

  @typedoc "A listed org-admin email that was not appointed, and why."
  @type refusal :: %{email: String.t(), reason: atom()}

  @typedoc "What a run did, or why it wrote nothing."
  @type summary ::
          %{
            status: :ok,
            organization: %{id: pos_integer(), name: String.t(), created: boolean()},
            appointed: [String.t()],
            already_org_admin: [String.t()],
            skipped_unknown: [String.t()],
            refused: [refusal()]
          }
          | %{status: :refused, reason: :unknown_acting_user | :not_site_admin}
          | %{status: :refused, reason: :invalid_organization, errors: %{atom() => [String.t()]}}

  @doc """
  Finds or creates the Organization named `name` and appoints each listed
  email's user as its org-admin, acting as the site admin with
  `acting_admin_email`.

  `opts` is a keyword list or map with:

    * `:acting_admin_email` — required; an enabled site admin's email.
    * `:name` — the Organization's name, `"#{@default_name}"` by default.
    * `:contact_name`, `:contact_email` — required only when the Organization
      is created; `:contact_phone` and the address fields are optional. They
      are ignored when the Organization already exists.
    * `:org_admin_emails` — the emails to appoint, `[]` by default.

  Returns a summary map. With `status: :ok` it names the Organization (with
  `created: true` only on the run that created it) and sorts every listed
  email into exactly one of `:appointed`, `:already_org_admin`,
  `:skipped_unknown` (no account; none is created) or `:refused` (with a
  reason such as `:already_in_another_organization` or `:user_disabled`).

  An unknown acting email (`:unknown_acting_user`), an acting user who is not
  an enabled site admin (`:not_site_admin`) and invalid Organization details
  (`:invalid_organization`, with the changeset's error messages) return
  `status: :refused` and write nothing.
  """
  @spec ensure(keyword() | map()) :: summary()
  def ensure(opts) do
    opts = Map.new(opts)

    with {:ok, actor} <- fetch_actor(opts[:acting_admin_email]),
         {:ok, organization, created?} <- find_or_create(opts, actor) do
      opts[:org_admin_emails]
      |> appoint_all(organization, actor)
      |> summarize(organization, created?)
    end
  end

  defp fetch_actor(email) when is_binary(email) do
    case email |> String.trim() |> Accounts.get_user_by_email() do
      %User{} = actor -> {:ok, actor}
      nil -> refused(:unknown_acting_user)
    end
  end

  defp fetch_actor(_email), do: refused(:unknown_acting_user)

  # The context decides who is a site admin, re-checking the database row, so
  # its refusal is the gate and nothing is written before it passes.
  defp list_organizations(actor) do
    case Organizations.list_organizations(actor) do
      {:ok, organizations} -> {:ok, organizations}
      {:error, :unauthorized} -> refused(:not_site_admin)
    end
  end

  # list_organizations/1 orders by name then id, so the first exact match is
  # the lowest id.
  defp find_or_create(opts, actor) do
    name = opts |> Map.get(:name, @default_name) |> trim()

    with {:ok, organizations} <- list_organizations(actor) do
      case Enum.find(organizations, &(&1.name == name)) do
        %Organization{} = organization -> {:ok, organization, false}
        nil -> create(name, opts, actor)
      end
    end
  end

  defp create(name, opts, actor) do
    attrs = opts |> Map.take(@organization_fields) |> Map.put(:name, name)

    case Organizations.create_organization(attrs, actor) do
      {:ok, organization} ->
        {:ok, organization, true}

      {:error, %Changeset{} = changeset} ->
        %{status: :refused, reason: :invalid_organization, errors: error_messages(changeset)}

      {:error, :unauthorized} ->
        refused(:not_site_admin)
    end
  end

  # Messages only: they are built from the validation's own text and options,
  # never from the submitted values.
  defp error_messages(changeset) do
    Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
  end

  defp appoint_all(emails, organization, actor) do
    emails
    |> List.wrap()
    |> normalize_emails()
    |> Enum.map(&appoint(&1, organization, actor))
  end

  # Trims, drops blanks and keeps the first spelling of each email, compared
  # case-insensitively as the citext column compares them.
  defp normalize_emails(emails) do
    emails
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(fn
      email when is_binary(email) -> String.downcase(email)
      other -> other
    end)
  end

  defp appoint(email, organization, actor) when is_binary(email) do
    case Accounts.get_user_by_email(email) do
      nil -> {:skipped_unknown, email}
      %User{disabled_at: nil} = user -> appoint_user(email, user, organization, actor)
      %User{} -> {:refused, %{email: email, reason: :user_disabled}}
    end
  end

  defp appoint(other, _organization, _actor),
    do: {:refused, %{email: inspect(other), reason: :invalid_email}}

  # appoint_org_admin/3 answers {:ok, _} for an existing org-admin too, so the
  # check first is what lets a re-run report it rather than count it again.
  defp appoint_user(email, user, organization, actor) do
    if Organizations.org_admin?(user, organization) do
      {:already_org_admin, email}
    else
      case Organizations.appoint_org_admin(actor, organization, user) do
        {:ok, _membership} -> {:appointed, email}
        {:error, %Changeset{}} -> {:refused, %{email: email, reason: :invalid_membership}}
        {:error, reason} -> {:refused, %{email: email, reason: reason}}
      end
    end
  end

  defp summarize(results, organization, created?) do
    grouped = Enum.group_by(results, &elem(&1, 0), &elem(&1, 1))

    %{
      status: :ok,
      organization: %{id: organization.id, name: organization.name, created: created?},
      appointed: Map.get(grouped, :appointed, []),
      already_org_admin: Map.get(grouped, :already_org_admin, []),
      skipped_unknown: Map.get(grouped, :skipped_unknown, []),
      refused: Map.get(grouped, :refused, [])
    }
  end

  defp refused(reason), do: %{status: :refused, reason: reason}

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
