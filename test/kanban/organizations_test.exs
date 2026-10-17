defmodule Kanban.OrganizationsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @created [:kanban, :organization, :created]
  @updated [:kanban, :organization, :updated]
  @member_added [:kanban, :organization, :member_added]
  @member_removed [:kanban, :organization, :member_removed]

  defp disabled_admin_fixture do
    admin_fixture()
    |> User.disabled_changeset(DateTime.utc_now(:second))
    |> Repo.update!()
  end

  # Runs `fun` once, in the test process, right after the first query that
  # matches `match?`, while the code under test is still inside its
  # transaction: the point where a concurrent writer could land.
  defp after_first_query(match?, fun) do
    test_pid = self()
    handler_id = "organizations-test-#{System.unique_integer([:positive])}"
    fired = :counters.new(1, [])

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and :counters.get(fired, 1) == 0 and match?.(metadata) do
          :counters.add(fired, 1, 1)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp membership_lookup?(%{source: "organization_members", query: query}),
    do: String.starts_with?(query, "SELECT") and query =~ "FOR UPDATE"

  defp membership_lookup?(_metadata), do: false

  defp role_of(user) do
    case Repo.get_by(OrganizationMember, user_id: user.id) do
      nil -> nil
      membership -> {membership.organization_id, membership.role}
    end
  end

  defp valid_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Acme Inc.",
      address_line1: "1 Main Street",
      city: "Toronto",
      region: "ON",
      postal_code: "M5V 1A1",
      country: "Canada",
      contact_name: "Ada Lovelace",
      contact_phone: "+1 416 555 0100",
      contact_email: "ada@acme.example"
    })
  end

  describe "Organization.changeset/2" do
    test "requires name, contact_name and contact_email" do
      changeset = Organization.changeset(%Organization{}, %{})

      assert %{
               name: ["can't be blank"],
               contact_name: ["can't be blank"],
               contact_email: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "accepts blank optional address fields" do
      changeset =
        Organization.changeset(
          %Organization{},
          valid_attrs(%{address_line1: "", address_line2: "", city: "", region: ""})
        )

      assert changeset.valid?
      assert get_field(changeset, :address_line1) == nil
      assert get_field(changeset, :city) == nil
    end

    test "validates the contact email format" do
      for email <- ["no-at-sign", "two@@example.com", "has space@example.com"] do
        changeset = Organization.changeset(%Organization{}, valid_attrs(%{contact_email: email}))
        assert %{contact_email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
      end
    end

    test "trims surrounding whitespace from the contact email and other fields" do
      changeset =
        Organization.changeset(
          %Organization{},
          valid_attrs(%{contact_email: "  ada@acme.example \n", name: "  Acme  "})
        )

      assert changeset.valid?
      assert get_field(changeset, :contact_email) == "ada@acme.example"
      assert get_field(changeset, :name) == "Acme"
    end

    test "redacts the contact fields from inspect" do
      organization =
        organization_fixture(%{
          contact_name: "Ada Lovelace",
          contact_phone: "+1 416 555 0100",
          contact_email: "ada@acme.example"
        })

      inspected = inspect(organization) <> inspect(Organization.changeset(organization, %{}))

      refute inspected =~ "Ada Lovelace"
      refute inspected =~ "+1 416 555 0100"
      refute inspected =~ "ada@acme.example"
      assert inspected =~ organization.name
    end

    test "treats a whitespace-only required field as missing" do
      changeset = Organization.changeset(%Organization{}, valid_attrs(%{name: "   "}))
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects, rather than truncates, a value over each field's cap" do
      for {field, max} <- Organization.max_lengths() do
        value =
          if field == :contact_email,
            do: String.duplicate("a", max) <> "@x.io",
            else: String.duplicate("a", max + 1)

        changeset = Organization.changeset(%Organization{}, valid_attrs(%{field => value}))

        refute changeset.valid?, "expected #{field} over #{max} characters to be rejected"
        assert errors_on(changeset)[field] |> Enum.any?(&(&1 =~ "should be at most"))
        assert get_change(changeset, field) == value
      end
    end

    test "accepts a value exactly at each field's cap" do
      for {field, max} <- Organization.max_lengths(), field != :contact_email do
        changeset =
          Organization.changeset(
            %Organization{},
            valid_attrs(%{field => String.duplicate("a", max)})
          )

        assert changeset.valid?, "expected #{field} of #{max} characters to be accepted"
      end
    end
  end

  describe "OrganizationMember.changeset/3" do
    test "sets the organization, user and role from its arguments" do
      organization = organization_fixture()
      user = user_fixture()

      changeset = OrganizationMember.changeset(organization.id, user.id, :org_admin)

      assert changeset.valid?
      assert get_field(changeset, :organization_id) == organization.id
      assert get_field(changeset, :user_id) == user.id
      assert get_field(changeset, :role) == :org_admin
    end

    test "rejects a role outside org_admin and member" do
      changeset = OrganizationMember.changeset(1, 1, :owner)
      assert %{role: ["is invalid"]} = errors_on(changeset)
    end

    test "requires every field" do
      changeset = OrganizationMember.changeset(nil, nil, nil)

      assert %{
               organization_id: ["can't be blank"],
               user_id: ["can't be blank"],
               role: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "a second membership for the same user is a changeset error, not a raise" do
      user = user_fixture()
      organization_member_fixture(organization_fixture(), user)

      assert {:error, changeset} =
               organization_fixture().id
               |> OrganizationMember.changeset(user.id, :member)
               |> Repo.insert()

      assert %{user_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "a membership for an organization that does not exist is a changeset error" do
      user = user_fixture()

      assert {:error, changeset} =
               -1 |> OrganizationMember.changeset(user.id, :member) |> Repo.insert()

      assert %{organization_id: ["does not exist"]} = errors_on(changeset)
    end

    test "the database rejects a role outside org_admin and member" do
      organization = organization_fixture()
      user = user_fixture()
      now = DateTime.utc_now(:second)

      assert_raise Postgrex.Error, ~r/organization_members_role_check/, fn ->
        Repo.insert_all("organization_members", [
          %{
            organization_id: organization.id,
            user_id: user.id,
            role: "owner",
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end

    test "deleting a user removes their membership" do
      organization = organization_fixture()
      user = user_fixture()
      membership = organization_member_fixture(organization, user)

      Repo.delete!(user)

      refute Repo.get(OrganizationMember, membership.id)
      assert Repo.get(Organization, organization.id)
    end

    test "an organization with members cannot be deleted" do
      organization = organization_fixture()
      organization_member_fixture(organization, user_fixture())

      assert_raise Ecto.ConstraintError, fn -> Repo.delete!(organization) end
    end
  end

  describe "OrganizationMember.role_changeset/2" do
    test "sets the role on an existing membership" do
      membership = organization_member_fixture(organization_fixture(), user_fixture())

      changeset = OrganizationMember.role_changeset(membership, :org_admin)

      assert changeset.valid?
      assert changeset.changes == %{role: :org_admin}
    end

    test "rejects a role outside org_admin and member" do
      membership = organization_member_fixture(organization_fixture(), user_fixture())

      assert %{role: ["is invalid"]} =
               errors_on(OrganizationMember.role_changeset(membership, :owner))

      assert %{role: ["can't be blank"]} =
               errors_on(OrganizationMember.role_changeset(membership, nil))
    end
  end

  describe "create_organization/2" do
    test "creates an Organization for an enabled site admin" do
      admin = admin_fixture()

      assert {:ok, %Organization{} = organization} =
               Organizations.create_organization(valid_attrs(), admin)

      assert organization.name == "Acme Inc."
      assert organization.contact_email == "ada@acme.example"
      assert Repo.get(Organization, organization.id)
    end

    test "returns :unauthorized for a regular user and writes nothing" do
      attach_telemetry(@created)

      assert {:error, :unauthorized} =
               Organizations.create_organization(valid_attrs(), user_fixture())

      assert Repo.aggregate(Organization, :count) == 0
      refute_received {:telemetry_event, @created, _, _}
    end

    test "returns :unauthorized for a disabled site admin" do
      assert {:error, :unauthorized} =
               Organizations.create_organization(valid_attrs(), disabled_admin_fixture())

      assert Repo.aggregate(Organization, :count) == 0
    end

    test "re-checks the database, so an admin disabled after loading is refused" do
      stale_admin = admin_fixture()

      stale_admin
      |> User.disabled_changeset(DateTime.utc_now(:second))
      |> Repo.update!()

      assert stale_admin.disabled_at == nil

      assert {:error, :unauthorized} =
               Organizations.create_organization(valid_attrs(), stale_admin)

      assert Repo.aggregate(Organization, :count) == 0
    end

    test "re-checks the database, so an admin demoted after loading is refused" do
      stale_admin = admin_fixture()
      {:ok, _} = Kanban.Accounts.update_user_type(stale_admin, :user)

      assert {:error, :unauthorized} =
               Organizations.update_organization(
                 organization_fixture(),
                 %{city: "X"},
                 stale_admin
               )

      assert {:error, :unauthorized} = Organizations.list_organizations(stale_admin)
    end

    test "returns the changeset for invalid attrs and emits nothing" do
      attach_telemetry(@created)

      assert {:error, %Ecto.Changeset{}} =
               Organizations.create_organization(%{name: "Acme"}, admin_fixture())

      refute_received {:telemetry_event, @created, _, _}
      assert AuditLog.list_events(action: :organization_created) == []
    end

    test "emits :created with organization_id and actor_user_id only" do
      attach_telemetry(@created)
      admin = admin_fixture()

      {:ok, organization} = Organizations.create_organization(valid_attrs(), admin)

      assert_received {:telemetry_event, @created, %{count: 1}, metadata}

      assert metadata == %{organization_id: organization.id, actor_user_id: admin.id}
    end

    test "records an :organization_created audit event carrying organization_id" do
      admin = admin_fixture()

      {:ok, organization} = Organizations.create_organization(valid_attrs(), admin)

      assert [event] = AuditLog.list_events(action: :organization_created)
      assert event.actor_user_id == admin.id
      assert event.metadata["organization_id"] == organization.id
      refute inspect(event.metadata) =~ "ada@acme.example"
    end
  end

  describe "update_organization/3" do
    test "changes the details for an enabled site admin" do
      organization = organization_fixture()

      assert {:ok, %Organization{city: "Ottawa"}} =
               Organizations.update_organization(organization, %{city: "Ottawa"}, admin_fixture())
    end

    test "returns :unauthorized for a regular user and for a disabled admin" do
      organization = organization_fixture(%{city: "Toronto"})

      for actor <- [user_fixture(), disabled_admin_fixture()] do
        assert {:error, :unauthorized} =
                 Organizations.update_organization(organization, %{city: "Ottawa"}, actor)
      end

      assert Repo.get!(Organization, organization.id).city == "Toronto"
    end

    test "emits :updated listing only the changed field names" do
      attach_telemetry(@updated)
      organization = organization_fixture()
      admin = admin_fixture()

      {:ok, _} =
        Organizations.update_organization(
          organization,
          %{city: "Ottawa", contact_email: "new@acme.example", name: organization.name},
          admin
        )

      assert_received {:telemetry_event, @updated, %{count: 1}, metadata}

      assert metadata == %{
               organization_id: organization.id,
               actor_user_id: admin.id,
               fields: [:city, :contact_email]
             }

      refute inspect(metadata) =~ "new@acme.example"
    end

    test "records an :organization_updated audit event carrying organization_id" do
      organization = organization_fixture()
      admin = admin_fixture()

      {:ok, _} = Organizations.update_organization(organization, %{city: "Ottawa"}, admin)

      assert [event] = AuditLog.list_events(action: :organization_updated)
      assert event.actor_user_id == admin.id
      assert event.metadata["organization_id"] == organization.id
    end

    test "an update that changes nothing emits and records nothing" do
      attach_telemetry(@updated)
      organization = organization_fixture()

      {:ok, _} =
        Organizations.update_organization(
          organization,
          %{name: organization.name},
          admin_fixture()
        )

      refute_received {:telemetry_event, @updated, _, _}
      assert AuditLog.list_events(action: :organization_updated) == []
    end

    test "an invalid update returns the changeset and emits nothing" do
      attach_telemetry(@updated)
      organization = organization_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Organizations.update_organization(
                 organization,
                 %{contact_email: "bad"},
                 admin_fixture()
               )

      refute_received {:telemetry_event, @updated, _, _}
    end
  end

  describe "list_organizations/1" do
    test "returns each Organization with its org-admin and member counts" do
      a = organization_fixture(%{name: "Alpha"})
      b = organization_fixture(%{name: "Bravo"})
      c = organization_fixture(%{name: "Charlie"})

      organization_member_fixture(a, user_fixture(), :org_admin)
      organization_member_fixture(a, user_fixture(), :member)
      organization_member_fixture(a, user_fixture(), :member)
      organization_member_fixture(b, user_fixture(), :org_admin)
      organization_member_fixture(b, user_fixture(), :org_admin)

      assert {:ok, organizations} = Organizations.list_organizations(admin_fixture())

      assert Enum.map(organizations, &{&1.id, &1.org_admin_count, &1.member_count}) == [
               {a.id, 1, 2},
               {b.id, 2, 0},
               {c.id, 0, 0}
             ]
    end

    test "runs a single query" do
      for _ <- 1..3 do
        organization = organization_fixture()
        organization_member_fixture(organization, user_fixture(), :org_admin)
      end

      admin = admin_fixture()
      test_pid = self()
      handler_id = "organizations-query-count-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kanban, :repo, :query],
        fn _event, _measurements, %{source: source}, _ ->
          if self() == test_pid and source in ["organizations", "organization_members"],
            do: send(test_pid, {:query, source})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, organizations} = Organizations.list_organizations(admin)

      assert length(organizations) == 3
      assert_received {:query, "organizations"}
      refute_received {:query, _}
    end

    test "returns :unauthorized for a regular user and for a disabled admin" do
      organization_fixture()

      assert {:error, :unauthorized} = Organizations.list_organizations(user_fixture())
      assert {:error, :unauthorized} = Organizations.list_organizations(disabled_admin_fixture())
    end
  end

  describe "get_organization/2" do
    test "returns the Organization to a site admin and to its org-admins" do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)

      assert %Organization{id: id} =
               Organizations.get_organization(organization.id, admin_fixture())

      assert id == organization.id
      assert %Organization{} = Organizations.get_organization(organization.id, org_admin)
    end

    test "returns nil to a member, a user outside it, a disabled admin and for a missing id" do
      organization = organization_fixture()
      member = user_fixture()
      organization_member_fixture(organization, member, :member)

      other_org_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_org_admin, :org_admin)

      for actor <- [member, user_fixture(), other_org_admin, disabled_admin_fixture()] do
        assert Organizations.get_organization(organization.id, actor) == nil
      end

      assert Organizations.get_organization(-1, admin_fixture()) == nil
    end
  end

  describe "get_membership/1" do
    test "returns nil for a user in no Organization" do
      assert Organizations.get_membership(user_fixture()) == nil
    end

    test "returns the membership with its Organization preloaded" do
      organization = organization_fixture()
      user = user_fixture()
      organization_member_fixture(organization, user, :org_admin)

      assert %OrganizationMember{role: :org_admin, organization: %Organization{id: id}} =
               Organizations.get_membership(user)

      assert id == organization.id
    end

    test "leaves the contact fields out of the preloaded Organization" do
      organization = organization_fixture(%{city: "Toronto", contact_phone: "+1 416 555 0100"})
      user = user_fixture()
      organization_member_fixture(organization, user, :member)

      %OrganizationMember{organization: loaded} = Organizations.get_membership(user)

      assert loaded.name == organization.name
      assert loaded.city == "Toronto"
      assert loaded.contact_name == nil
      assert loaded.contact_phone == nil
      assert loaded.contact_email == nil
    end
  end

  describe "org_admin?/2 and member?/2" do
    setup do
      first = organization_fixture()
      second = organization_fixture()
      org_admin = user_fixture()
      member = user_fixture()
      organization_member_fixture(first, org_admin, :org_admin)
      organization_member_fixture(first, member, :member)

      %{first: first, second: second, org_admin: org_admin, member: member}
    end

    test "org_admin?/2 is true only for an org_admin of that Organization", ctx do
      assert Organizations.org_admin?(ctx.org_admin, ctx.first)
      assert Organizations.org_admin?(ctx.org_admin, ctx.first.id)
      refute Organizations.org_admin?(ctx.member, ctx.first)
      refute Organizations.org_admin?(ctx.org_admin, ctx.second)
      refute Organizations.org_admin?(user_fixture(), ctx.first)
    end

    test "member?/2 is true for either role in that Organization only", ctx do
      assert Organizations.member?(ctx.org_admin, ctx.first)
      assert Organizations.member?(ctx.member, ctx.first.id)
      refute Organizations.member?(ctx.member, ctx.second)
      refute Organizations.member?(ctx.org_admin, ctx.second)
      refute Organizations.member?(user_fixture(), ctx.first)
    end
  end

  describe "list_members/1" do
    test "returns the memberships with users preloaded, org-admins first" do
      organization = organization_fixture()
      member = user_fixture(%{email: "aaa#{System.unique_integer([:positive])}@example.com"})
      org_admin = user_fixture(%{email: "zzz#{System.unique_integer([:positive])}@example.com"})
      organization_member_fixture(organization, member, :member)
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization_fixture(), user_fixture())

      members = Organizations.list_members(organization)

      assert Enum.map(members, &{&1.user.id, &1.role}) == [
               {org_admin.id, :org_admin},
               {member.id, :member}
             ]

      assert Organizations.list_members(organization.id) |> length() == 2
    end

    test "returns an empty list for an Organization with no members" do
      assert Organizations.list_members(organization_fixture()) == []
    end
  end

  describe "add_member/3" do
    test "adds a user with no Organization as a member and emits :member_added" do
      attach_telemetry(@member_added)
      organization = organization_fixture()
      user = user_fixture()

      assert {:ok, %OrganizationMember{role: :member} = membership} =
               Organizations.add_member(organization, user, :member)

      assert membership.organization_id == organization.id
      assert role_of(user) == {organization.id, :member}

      assert_received {:telemetry_event, @member_added, %{count: 1}, metadata}

      assert metadata == %{
               organization_id: organization.id,
               user_id: user.id,
               role: :member,
               actor_user_id: user.id
             }
    end

    test "accepts an organization id" do
      organization = organization_fixture()
      user = user_fixture()

      assert {:ok, %OrganizationMember{}} =
               Organizations.add_member(organization.id, user, :member)

      assert role_of(user) == {organization.id, :member}
    end

    test "is a no-op success for a member of the same Organization" do
      organization = organization_fixture()
      user = user_fixture()
      existing = organization_member_fixture(organization, user)
      attach_telemetry(@member_added)

      assert {:ok, %OrganizationMember{id: id, role: :member}} =
               Organizations.add_member(organization, user, :member)

      assert id == existing.id
      assert Repo.aggregate(OrganizationMember, :count) == 1
      refute_received {:telemetry_event, @member_added, _, _}
    end

    test "never downgrades an org-admin of the same Organization" do
      organization = organization_fixture()
      user = user_fixture()
      organization_member_fixture(organization, user, :org_admin)

      assert {:ok, %OrganizationMember{role: :org_admin}} =
               Organizations.add_member(organization, user, :member)

      assert role_of(user) == {organization.id, :org_admin}
    end

    test "refuses a user in another Organization and writes nothing" do
      other = organization_fixture()
      user = user_fixture()
      organization_member_fixture(other, user)
      attach_telemetry(@member_added)

      assert {:error, :already_in_another_organization} =
               Organizations.add_member(organization_fixture(), user, :member)

      assert role_of(user) == {other.id, :member}
      refute_received {:telemetry_event, @member_added, _, _}
    end

    test "maps a unique-index race to :already_in_another_organization" do
      organization = organization_fixture()
      other = organization_fixture()
      user = user_fixture()
      attach_telemetry(@member_added)

      # A concurrent writer gives the user a membership after the lookup
      # found none and before the insert runs.
      after_first_query(&membership_lookup?/1, fn ->
        organization_member_fixture(other, user)
      end)

      assert {:error, :already_in_another_organization} =
               Organizations.add_member(organization, user, :member)

      refute_received {:telemetry_event, @member_added, _, _}
    end

    test "returns a changeset error for a user deleted before the write" do
      organization = organization_fixture()
      user = user_fixture()
      Repo.delete!(user)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organizations.add_member(organization, user, :member)

      assert %{user_id: ["does not exist"]} = errors_on(changeset)
      assert Repo.aggregate(OrganizationMember, :count) == 0
    end

    test "returns :not_found for an Organization that does not exist" do
      assert {:error, :not_found} = Organizations.add_member(-1, user_fixture(), :member)
    end
  end

  describe "appoint_org_admin/3" do
    test "appoints a user with no Organization, emits :member_added and records the audit event" do
      attach_telemetry(@member_added)
      admin = admin_fixture()
      organization = organization_fixture()
      user = user_fixture()

      assert {:ok, %OrganizationMember{role: :org_admin}} =
               Organizations.appoint_org_admin(admin, organization, user)

      assert role_of(user) == {organization.id, :org_admin}

      assert_received {:telemetry_event, @member_added, %{count: 1}, metadata}

      assert metadata == %{
               organization_id: organization.id,
               user_id: user.id,
               role: :org_admin,
               actor_user_id: admin.id
             }

      assert [event] = AuditLog.list_events(action: :org_admin_appointed)
      assert event.actor_user_id == admin.id
      assert event.metadata["organization_id"] == organization.id
      assert event.metadata["member_user_id"] == user.id
    end

    test "promotes a member of the same Organization without emitting :member_added" do
      admin = admin_fixture()
      organization = organization_fixture()
      user = user_fixture()
      existing = organization_member_fixture(organization, user)
      attach_telemetry(@member_added)

      assert {:ok, %OrganizationMember{id: id, role: :org_admin}} =
               Organizations.appoint_org_admin(admin, organization, user)

      assert id == existing.id
      assert role_of(user) == {organization.id, :org_admin}
      refute_received {:telemetry_event, @member_added, _, _}

      assert [event] = AuditLog.list_events(action: :org_admin_appointed)
      assert event.metadata["member_user_id"] == user.id
    end

    test "is a no-op success for a user who is already an org-admin" do
      admin = admin_fixture()
      organization = organization_fixture()
      user = user_fixture()
      existing = organization_member_fixture(organization, user, :org_admin)
      attach_telemetry(@member_added)

      assert {:ok, %OrganizationMember{id: id, role: :org_admin}} =
               Organizations.appoint_org_admin(admin, organization, user)

      assert id == existing.id
      refute_received {:telemetry_event, @member_added, _, _}
      assert AuditLog.list_events(action: :org_admin_appointed) == []
    end

    test "refuses a user in another Organization and writes nothing" do
      other = organization_fixture()
      user = user_fixture()
      organization_member_fixture(other, user)

      assert {:error, :already_in_another_organization} =
               Organizations.appoint_org_admin(admin_fixture(), organization_fixture(), user)

      assert role_of(user) == {other.id, :member}
      assert AuditLog.list_events(action: :org_admin_appointed) == []
    end

    test "refuses every actor but an enabled site admin, including an org-admin" do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      user = user_fixture()
      attach_telemetry(@member_added)

      for actor <- [user_fixture(), org_admin, disabled_admin_fixture()] do
        assert {:error, :unauthorized} =
                 Organizations.appoint_org_admin(actor, organization, user)
      end

      assert role_of(user) == nil
      refute_received {:telemetry_event, @member_added, _, _}
      assert AuditLog.list_events(action: :org_admin_appointed) == []
    end

    test "returns a changeset error for a user deleted before the write" do
      user = user_fixture()
      Repo.delete!(user)

      assert {:error, %Ecto.Changeset{}} =
               Organizations.appoint_org_admin(admin_fixture(), organization_fixture(), user)

      assert AuditLog.list_events(action: :org_admin_appointed) == []
    end

    test "maps a unique-index race to :already_in_another_organization" do
      user = user_fixture()
      other = organization_fixture()

      after_first_query(&membership_lookup?/1, fn ->
        organization_member_fixture(other, user)
      end)

      assert {:error, :already_in_another_organization} =
               Organizations.appoint_org_admin(admin_fixture(), organization_fixture(), user)

      assert AuditLog.list_events(action: :org_admin_appointed) == []
    end
  end

  describe "remove_org_admin/3" do
    setup do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      %{organization: organization, org_admin: org_admin, admin: admin_fixture()}
    end

    test "refuses to remove the last org-admin while other members remain", ctx do
      organization_member_fixture(ctx.organization, user_fixture())
      attach_telemetry(@member_removed)

      assert {:error, :last_org_admin} =
               Organizations.remove_org_admin(ctx.admin, ctx.organization, ctx.org_admin)

      assert role_of(ctx.org_admin) == {ctx.organization.id, :org_admin}
      refute_received {:telemetry_event, @member_removed, _, _}
      assert AuditLog.list_events(action: :org_admin_removed) == []
    end

    test "removes the only org-admin of an Organization with no other members", ctx do
      attach_telemetry(@member_removed)

      assert {:ok, %OrganizationMember{role: :org_admin}} =
               Organizations.remove_org_admin(ctx.admin, ctx.organization, ctx.org_admin)

      assert role_of(ctx.org_admin) == nil

      assert_received {:telemetry_event, @member_removed, %{count: 1}, metadata}

      assert metadata == %{
               organization_id: ctx.organization.id,
               user_id: ctx.org_admin.id,
               role: :org_admin,
               actor_user_id: ctx.admin.id
             }

      assert [event] = AuditLog.list_events(action: :org_admin_removed)
      assert event.actor_user_id == ctx.admin.id
      assert event.metadata["organization_id"] == ctx.organization.id
      assert event.metadata["member_user_id"] == ctx.org_admin.id
    end

    test "removes one of two org-admins while members remain", ctx do
      second = user_fixture()
      organization_member_fixture(ctx.organization, second, :org_admin)
      organization_member_fixture(ctx.organization, user_fixture())

      assert {:ok, _membership} =
               Organizations.remove_org_admin(ctx.admin, ctx.organization.id, ctx.org_admin)

      assert role_of(ctx.org_admin) == nil
      assert role_of(second) == {ctx.organization.id, :org_admin}

      assert {:error, :last_org_admin} =
               Organizations.remove_org_admin(ctx.admin, ctx.organization, second)
    end

    test "returns :not_found for a member who is not an org-admin, and leaves them", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)

      assert {:error, :not_found} =
               Organizations.remove_org_admin(ctx.admin, ctx.organization, member)

      assert role_of(member) == {ctx.organization.id, :member}
    end

    test "returns :not_found for an org-admin of another Organization", ctx do
      assert {:error, :not_found} =
               Organizations.remove_org_admin(ctx.admin, organization_fixture(), ctx.org_admin)

      assert role_of(ctx.org_admin) == {ctx.organization.id, :org_admin}
    end

    test "returns :not_found for a user deleted before the removal", ctx do
      Repo.delete!(ctx.org_admin)

      assert {:error, :not_found} =
               Organizations.remove_org_admin(ctx.admin, ctx.organization, ctx.org_admin)

      assert AuditLog.list_events(action: :org_admin_removed) == []
    end

    test "refuses every actor but an enabled site admin, including an org-admin", ctx do
      other_org_admin = user_fixture()
      organization_member_fixture(ctx.organization, other_org_admin, :org_admin)

      for actor <- [user_fixture(), other_org_admin, disabled_admin_fixture()] do
        assert {:error, :unauthorized} =
                 Organizations.remove_org_admin(actor, ctx.organization, ctx.org_admin)
      end

      assert role_of(ctx.org_admin) == {ctx.organization.id, :org_admin}
      assert AuditLog.list_events(action: :org_admin_removed) == []
    end

    test "takes a row lock on the organization before its check", ctx do
      test_pid = self()
      handler_id = "organizations-lock-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kanban, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:query, metadata.source, metadata.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Organizations.remove_org_admin(ctx.admin, ctx.organization, ctx.org_admin)

      queries = collect_queries([])
      lock_index = Enum.find_index(queries, &organization_lock?/1)

      membership_query_index =
        Enum.find_index(queries, &match?({"organization_members", "SELECT" <> _}, &1))

      assert lock_index, "expected a FOR UPDATE query on organizations"
      assert lock_index < membership_query_index
    end
  end

  defp collect_queries(acc) do
    receive do
      {:query, source, query} -> collect_queries([{source, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp organization_lock?({"organizations", query}), do: query =~ "FOR UPDATE"
  defp organization_lock?(_query), do: false

  describe "the context's public functions" do
    test "include no delete or downgrade function" do
      functions = Organizations.__info__(:functions) |> Keyword.keys()

      refute Enum.any?(functions, fn name ->
               name |> Atom.to_string() |> String.contains?(["delete", "downgrade"])
             end)
    end
  end
end
