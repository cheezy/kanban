defmodule Kanban.WorkspacesTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  defp org_with_admin do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    {organization, admin}
  end

  defp org_member(organization) do
    user = user_fixture()
    organization_member_fixture(organization, user, :member)
    user
  end

  # A personal workspace row with no owner, for exercising the owner rules.
  defp bare_personal_workspace do
    %{name: "Bare"}
    |> Workspace.create_changeset(true, nil)
    |> Repo.insert!()
  end

  defp workspace_count, do: Repo.aggregate(Workspace, :count)

  defp org_workspaces_of(organization),
    do: Workspace |> where([w], w.organization_id == ^organization.id) |> Repo.all()

  # Disables `user` in the database and returns the stale struct, still
  # enabled, so a check that trusts the struct would let them through.
  defp disable(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
    user
  end

  describe "WorkspaceMember roles" do
    test "roles/0 is owner, member and guest, with no admin" do
      assert WorkspaceMember.roles() == [:owner, :member, :guest]
      refute :admin in WorkspaceMember.roles()
    end

    test "changeset/3 rejects admin, unknown and string roles" do
      for role <- [:admin, :bogus, "member", nil] do
        changeset = WorkspaceMember.changeset(1, 1, role)
        refute changeset.valid?
        assert %{role: ["is invalid"]} = errors_on(changeset)
      end
    end

    test "role_changeset/2 rejects a role outside roles/0" do
      changeset = WorkspaceMember.role_changeset(%WorkspaceMember{role: :member}, :admin)
      assert %{role: ["is invalid"]} = errors_on(changeset)
    end

    test "the database rejects a role outside owner, member and guest" do
      {organization, _admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      user = org_member(organization)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "workspace_members_role_check"}}} =
               Repo.query(
                 "INSERT INTO workspace_members (workspace_id, user_id, role, inserted_at, updated_at) " <>
                   "VALUES ($1, $2, 'admin', now(), now())",
                 [workspace.id, user.id]
               )
    end
  end

  describe "database owner rules" do
    test "a second owner row on a workspace is a changeset error" do
      owner = user_fixture()
      workspace = personal_workspace_fixture(owner)

      assert {:error, changeset} =
               workspace.id
               |> WorkspaceMember.changeset(user_fixture().id, :owner)
               |> Repo.insert()

      assert %{workspace_id: ["workspace already has an owner"]} = errors_on(changeset)
    end

    test "a second owned workspace for the same user is a changeset error" do
      owner = user_fixture()
      personal_workspace_fixture(owner)
      other = bare_personal_workspace()

      assert {:error, changeset} =
               other.id |> WorkspaceMember.changeset(owner.id, :owner) |> Repo.insert()

      assert %{user_id: ["already owns a workspace"]} = errors_on(changeset)
    end

    test "a second row for the same workspace and user is a changeset error" do
      {organization, _admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      user = org_member(organization)
      workspace_member_fixture(workspace, user, :member)

      assert {:error, changeset} =
               workspace.id |> WorkspaceMember.changeset(user.id, :guest) |> Repo.insert()

      assert %{user_id: ["is already a member of this workspace"]} = errors_on(changeset)
    end

    test "the trigger rejects an owner row on an org workspace" do
      {organization, admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)

      assert {:error, changeset} =
               workspace.id |> WorkspaceMember.changeset(admin.id, :owner) |> Repo.insert()

      assert %{role: ["owner is only allowed on a personal workspace"]} = errors_on(changeset)
    end

    test "the trigger rejects member and guest rows on a personal workspace" do
      workspace = personal_workspace_fixture(user_fixture())

      for role <- [:member, :guest] do
        assert {:error, changeset} =
                 workspace.id
                 |> WorkspaceMember.changeset(user_fixture().id, role)
                 |> Repo.insert()

        assert %{role: ["a personal workspace has only its owner"]} = errors_on(changeset)
      end
    end

    test "the trigger rejects demoting a personal workspace's owner row" do
      owner = user_fixture()
      workspace = personal_workspace_fixture(owner)
      owner_row = Repo.get_by!(WorkspaceMember, workspace_id: workspace.id, user_id: owner.id)

      assert {:error, changeset} =
               owner_row |> WorkspaceMember.role_changeset(:member) |> Repo.update()

      assert %{role: ["a personal workspace has only its owner"]} = errors_on(changeset)
    end

    test "the database refuses to flip a workspace between personal and org" do
      {organization, _admin} = org_with_admin()
      personal = personal_workspace_fixture(user_fixture())
      org_workspace = org_workspace_fixture(organization)

      assert {:error, %Postgrex.Error{postgres: %{constraint: "workspaces_personal_immutable"}}} =
               Repo.query(
                 "UPDATE workspaces SET personal = false, organization_id = $1 WHERE id = $2",
                 [organization.id, personal.id]
               )

      assert {:error, %Postgrex.Error{postgres: %{constraint: "workspaces_personal_immutable"}}} =
               Repo.query(
                 "UPDATE workspaces SET personal = true, organization_id = NULL WHERE id = $1",
                 [org_workspace.id]
               )
    end
  end

  describe "Workspace.create_changeset/3" do
    test "the database rejects a personal workspace with an organization" do
      organization = organization_fixture()

      assert {:error, changeset} =
               %{name: "Mixed"}
               |> Workspace.create_changeset(true, organization.id)
               |> Repo.insert()

      assert %{personal: [_message]} = errors_on(changeset)
    end

    test "the database rejects a non-personal workspace without an organization" do
      assert {:error, changeset} =
               %{name: "Orphan"} |> Workspace.create_changeset(false, nil) |> Repo.insert()

      assert %{personal: [_message]} = errors_on(changeset)
    end

    test "casts only the name, never personal, organization_id, slug or archived_at" do
      organization = organization_fixture()
      other_organization = organization_fixture()

      changeset =
        Workspace.create_changeset(
          %{
            name: "Design",
            personal: true,
            organization_id: other_organization.id,
            slug: "chosen",
            archived_at: DateTime.utc_now(:second)
          },
          false,
          organization.id
        )

      assert changeset.valid?
      assert get_field(changeset, :personal) == false
      assert get_field(changeset, :organization_id) == organization.id
      assert get_field(changeset, :archived_at) == nil
      refute get_field(changeset, :slug) == "chosen"
    end

    test "requires a name and limits its length" do
      assert %{name: ["can't be blank"]} =
               errors_on(Workspace.create_changeset(%{name: "   "}, true, nil))

      assert %{name: ["should be at most 100 character(s)"]} =
               errors_on(
                 Workspace.create_changeset(%{name: String.duplicate("a", 101)}, true, nil)
               )
    end

    test "an invalid name reports the name alone, never a blank slug" do
      for name <- ["   ", String.duplicate("a", 101), <<"De", 0, "sign">>] do
        errors = errors_on(Workspace.create_changeset(%{name: name}, true, nil))
        assert Map.keys(errors) == [:name]
      end
    end

    test "normalizes names to NFC and strips zero-width characters" do
      decomposed = "E\u0301cole"
      precomposed = "\u00C9cole"

      assert get_field(Workspace.create_changeset(%{name: decomposed}, true, nil), :name) ==
               precomposed

      for hidden <- ["Des\u200Bign", "\uFEFFDesign\u2060", " \u200B Design \u200B "] do
        assert get_field(Workspace.create_changeset(%{name: hidden}, true, nil), :name) ==
                 "Design"
      end

      workspace = bare_personal_workspace()
      renamed = Workspace.changeset(workspace, %{name: "Re\u200Bnamed"})
      assert get_change(renamed, :name) == "Renamed"
    end

    # Built from code points: the source must not hold bidirectional controls.
    defp chars(codepoints), do: List.to_string(codepoints)

    test "strips direction marks, overrides and every other invisible character" do
      for hidden <- [
            chars(~c"Design" ++ [0x200E]),
            chars([0x200F] ++ ~c"Design"),
            chars([0x202E] ++ ~c"Design" ++ [0x202C]),
            chars([0x2066] ++ ~c"Design" ++ [0x2069]),
            chars(~c"De" ++ [0x00AD] ++ ~c"sign"),
            chars(~c"Des" ++ [0x034F] ++ ~c"ign"),
            chars(~c"Design" ++ [0xE0067, 0xE007F]),
            chars(~c"Design" ++ [0x3164]),
            chars([0x115F, 0x1160] ++ ~c"Design" ++ [0xFFA0]),
            chars(~c"Design" ++ [0x17B4, 0x17B5]),
            chars(~c"Design" ++ [0x180E, 0x061C, 0x2061])
          ] do
        assert get_field(Workspace.create_changeset(%{name: hidden}, true, nil), :name) ==
                 "Design",
               "expected #{inspect(String.to_charlist(hidden))} to normalize to Design"
      end
    end

    test "an override can no longer disguise reversed letters" do
      spoof = chars(~c"RT " ++ [0x202E] ++ ~c"ngiseD")

      assert get_field(Workspace.create_changeset(%{name: spoof}, true, nil), :name) ==
               "RT ngiseD"
    end

    test "a name of only invisible characters is blank" do
      for blank <- [[0x200E], [0x034F], [0x3164], [0x202E, 0x200F], [0x00AD]] do
        assert %{name: ["can't be blank"]} =
                 errors_on(Workspace.create_changeset(%{name: chars(blank)}, true, nil))
      end
    end

    test "keeps variation selectors, so emoji keep their presentation" do
      heart = chars([0x2764, 0xFE0F])

      assert get_field(Workspace.create_changeset(%{name: heart}, true, nil), :name) == heart
    end

    test "keeps the joiners that scripts and emoji need" do
      persian = "\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645"
      family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}"

      for name <- [persian, family] do
        assert get_field(Workspace.create_changeset(%{name: name}, true, nil), :name) == name
      end
    end

    test "a name of only zero-width characters is blank" do
      assert %{name: ["can't be blank"]} =
               errors_on(Workspace.create_changeset(%{name: "\u200B\uFEFF"}, true, nil))
    end

    test "the not-allowed-characters error is translated in every locale" do
      for locale <- ~w(de es fr ja pt zh) do
        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            KanbanWeb.CoreComponents.translate_error(
              {"contains characters that are not allowed", []}
            )
          end)

        assert translated != "contains characters that are not allowed",
               "no #{locale} translation"
      end
    end

    test "a NUL byte or invalid UTF-8 is a name error, not a database error" do
      for name <- [<<"De", 0, "sign">>, <<"Design", 0xFF>>, <<0xC3>>] do
        changeset = Workspace.create_changeset(%{name: name}, true, nil)
        refute changeset.valid?
        assert %{name: ["contains characters that are not allowed"]} = errors_on(changeset)
      end

      workspace = bare_personal_workspace()

      assert {:error, changeset} =
               workspace |> Workspace.changeset(%{name: <<"Bad", 0>>}) |> Repo.update()

      assert %{name: ["contains characters that are not allowed"]} = errors_on(changeset)
    end

    test "slugs fold accents, fall back for non-Latin names and never collide" do
      latin = Workspace.create_changeset(%{name: "Café Déjà Vu!"}, true, nil)
      assert get_field(latin, :slug) =~ ~r/\Acafe-deja-vu-[a-z2-7]{8}\z/

      non_latin = Workspace.create_changeset(%{name: "日本語"}, true, nil)
      assert get_field(non_latin, :slug) =~ ~r/\Aworkspace-[a-z2-7]{8}\z/

      first = Workspace.create_changeset(%{name: "Same"}, true, nil)
      second = Workspace.create_changeset(%{name: "Same"}, true, nil)
      refute get_field(first, :slug) == get_field(second, :slug)
    end

    test "slug_base/1 caps the base and handles invalid unicode" do
      long_base = "ab " |> String.duplicate(40) |> Workspace.slug_base()
      assert String.length(long_base) <= 40
      refute String.ends_with?(long_base, "-")
      assert Workspace.slug_base(<<0xFF, 0xFE>>) == "workspace"
    end

    test "a duplicate slug is a changeset error" do
      first = bare_personal_workspace()

      assert {:error, changeset} =
               %{name: "Copy"}
               |> Workspace.create_changeset(true, nil)
               |> put_change(:slug, first.slug)
               |> Repo.insert()

      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "renaming keeps the slug" do
      workspace = bare_personal_workspace()

      {:ok, renamed} =
        workspace |> Workspace.changeset(%{name: "Renamed", slug: "x"}) |> Repo.update()

      assert renamed.name == "Renamed"
      assert renamed.slug == workspace.slug
    end

    test "renaming to an empty or blank name is an error, not a crash" do
      workspace = bare_personal_workspace()

      for name <- ["", "   ", nil] do
        changeset = Workspace.changeset(workspace, %{name: name})

        refute changeset.valid?
        assert %{name: ["can't be blank"]} = errors_on(changeset)
      end
    end

    test "has no plan, seat or billing field in the schema or the table" do
      schema_fields =
        Enum.map(
          Workspace.__schema__(:fields) ++ Workspace.__schema__(:virtual_fields),
          &to_string/1
        )

      %{rows: rows} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'workspaces'"
        )

      columns = List.flatten(rows)
      assert "organization_id" in columns

      refute Enum.any?(schema_fields ++ columns, &(&1 =~ ~r/plan|seat|billing/))
    end
  end

  describe "create_personal_workspace/1" do
    test "creates the personal workspace and a single owner row" do
      user = remove_personal_workspace(user_fixture())

      assert {:ok, %Workspace{personal: true, organization_id: nil} = workspace} =
               Workspaces.create_personal_workspace(user)

      assert [%WorkspaceMember{user_id: user_id, role: :owner}] =
               WorkspaceMember |> where([m], m.workspace_id == ^workspace.id) |> Repo.all()

      assert user_id == user.id
    end

    test "a second call is a changeset error and leaves no orphan workspace" do
      user = user_fixture()
      personal_workspace_fixture(user)
      count = workspace_count()

      assert {:error, changeset} = Workspaces.create_personal_workspace(user)
      assert %{user_id: ["already owns a workspace"]} = errors_on(changeset)
      assert workspace_count() == count
    end
  end

  describe "ensure_personal_workspace/1" do
    test "creates the workspace and owner row once, then returns the same one" do
      user = remove_personal_workspace(user_fixture())
      count = workspace_count()

      assert {:ok, %Workspace{personal: true} = workspace} =
               Workspaces.ensure_personal_workspace(user)

      assert {:ok, again} = Workspaces.ensure_personal_workspace(user)
      assert again.id == workspace.id
      assert workspace_count() == count + 1

      assert [%WorkspaceMember{role: :owner}] =
               WorkspaceMember |> where([m], m.user_id == ^user.id) |> Repo.all()
    end

    test "returns the changeset and leaves nothing behind when creation fails" do
      count = workspace_count()

      # No such user, so the owner row's foreign key fails after the workspace
      # insert; the transaction must roll the workspace back too.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Workspaces.ensure_personal_workspace(%User{id: -1})

      assert %{user_id: [_message]} = errors_on(changeset)
      assert workspace_count() == count
    end

    test "returns the personal workspace a registered user already has" do
      user = user_fixture()
      existing = Workspaces.get_personal_workspace(user)

      assert {:ok, %Workspace{id: id}} = Workspaces.ensure_personal_workspace(user)
      assert id == existing.id
    end
  end

  describe "get_personal_workspace/1" do
    test "returns the user's personal workspace" do
      user = user_fixture()
      workspace = personal_workspace_fixture(user)

      assert %Workspace{id: id} = Workspaces.get_personal_workspace(user)
      assert id == workspace.id
    end

    test "returns nil for a user with no workspaces yet" do
      user = remove_personal_workspace(user_fixture())
      assert Workspaces.get_personal_workspace(user) == nil
    end

    test "does not return an org workspace the user is a member of" do
      {organization, _admin} = org_with_admin()
      user = organization |> org_member() |> remove_personal_workspace()
      organization |> org_workspace_fixture() |> workspace_member_fixture(user)

      assert Workspaces.get_personal_workspace(user) == nil
    end
  end

  # A board in `user`'s personal workspace with no board_users row for them.
  defp place_board_in_personal_workspace(user) do
    workspace = Workspaces.get_personal_workspace(user)
    {place_board_in_workspace(workspace), workspace}
  end

  describe "delete_personal_workspace/1" do
    test "deletes an empty personal workspace and its owner row" do
      user = user_fixture()
      workspace = personal_workspace_fixture(user)

      assert {:ok, %Workspace{id: id}} = Workspaces.delete_personal_workspace(user)
      assert id == workspace.id
      assert Repo.get(Workspace, workspace.id) == nil
      refute WorkspaceMember |> where([m], m.workspace_id == ^workspace.id) |> Repo.exists?()
      assert Workspaces.get_personal_workspace(user) == nil
    end

    test "returns {:ok, nil} for a user with no personal workspace" do
      user = remove_personal_workspace(user_fixture())

      assert Workspaces.delete_personal_workspace(user) == {:ok, nil}
    end

    test "refuses while a board the user owns sits in it, and deletes nothing" do
      user = user_fixture()
      board = board_fixture(user)
      workspace = personal_workspace_fixture(user)

      assert Workspaces.delete_personal_workspace(user) ==
               {:error, :personal_workspace_has_boards}

      assert Repo.get(Workspace, workspace.id)
      assert Repo.get!(Board, board.id).workspace_id == workspace.id
    end

    test "refuses through the foreign key for a board the user is not a member of" do
      user = user_fixture()
      {board, workspace} = place_board_in_personal_workspace(user)

      assert Workspaces.delete_personal_workspace(user) ==
               {:error, :personal_workspace_has_boards}

      assert Repo.get(Workspace, workspace.id)
      assert Repo.get!(Board, board.id).workspace_id == workspace.id
      assert Workspaces.get_member_role(workspace, user) == :owner
    end

    test "never deletes an org workspace the user is a member or guest of" do
      {organization, _admin} = org_with_admin()
      user = org_member(organization)
      member_of = org_workspace_fixture(organization)
      guest_of = org_workspace_fixture(organization)
      workspace_member_fixture(member_of, user, :member)
      workspace_member_fixture(guest_of, user, :guest)

      assert {:ok, %Workspace{personal: true}} = Workspaces.delete_personal_workspace(user)
      assert Repo.get(Workspace, member_of.id)
      assert Repo.get(Workspace, guest_of.id)
      assert Workspaces.get_member_role(member_of, user) == :member
      assert Workspaces.get_member_role(guest_of, user) == :guest

      assert Workspaces.delete_personal_workspace(user) == {:ok, nil}
      assert Repo.get(Workspace, member_of.id)
    end

    test "never deletes another user's personal workspace" do
      user = user_fixture()
      other = user_fixture()
      others = personal_workspace_fixture(other)

      assert {:ok, _} = Workspaces.delete_personal_workspace(user)
      assert Repo.get(Workspace, others.id)
      assert Workspaces.get_member_role(others, other) == :owner
    end
  end

  describe "create_org_workspace/2" do
    test "an org-admin creates a workspace for their Organization with no owner row" do
      {organization, admin} = org_with_admin()

      assert {:ok, %Workspace{personal: false} = workspace} =
               Workspaces.create_org_workspace(%{name: "Design"}, admin)

      assert workspace.organization_id == organization.id

      refute WorkspaceMember |> where([m], m.workspace_id == ^workspace.id) |> Repo.exists?()
    end

    test "ignores organization_id and personal in attrs" do
      {organization, admin} = org_with_admin()
      other_organization = organization_fixture()

      assert {:ok, workspace} =
               Workspaces.create_org_workspace(
                 %{
                   "name" => "Design",
                   "organization_id" => other_organization.id,
                   "personal" => true
                 },
                 admin
               )

      assert workspace.organization_id == organization.id
      assert workspace.personal == false
    end

    test "refuses a plain member, a user in no Organization and a site admin" do
      {organization, _admin} = org_with_admin()

      for actor <- [org_member(organization), user_fixture(), admin_fixture()] do
        assert Workspaces.create_org_workspace(%{name: "Design"}, actor) ==
                 {:error, :unauthorized}
      end
    end

    test "refuses a disabled org-admin, read from the database" do
      {organization, admin} = org_with_admin()
      count = workspace_count()

      assert Workspaces.create_org_workspace(%{name: "Design"}, disable(admin)) ==
               {:error, :unauthorized}

      assert workspace_count() == count
      assert org_workspaces_of(organization) == []
    end

    test "a blank name is a changeset error" do
      {_organization, admin} = org_with_admin()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Workspaces.create_org_workspace(%{name: ""}, admin)

      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "the workspace name rule" do
    test "personal workspaces are outside the name rule" do
      owners = for _ <- 1..3, do: user_fixture()
      personal = Enum.map(owners, &Workspaces.get_personal_workspace/1)

      assert Enum.map(personal, & &1.name) == ["Personal", "Personal", "Personal"]
      assert personal |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3

      {organization, admin} = org_with_admin()

      assert {:ok, %Workspace{name: "Personal"}} =
               Workspaces.create_org_workspace(%{name: "Personal"}, admin)

      org_workspace_fixture(organization, %{
        name: "Design",
        archived_at: DateTime.utc_now(:second)
      })

      assert {:ok, %Workspace{name: "design"}} =
               Workspaces.create_org_workspace(%{name: "design"}, admin)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Workspaces.create_org_workspace(%{name: "DESIGN"}, admin)

      assert errors_on(changeset) == %{name: ["has already been taken"]}
    end

    test "names that only differ in normalization or hidden characters are one name" do
      {_organization, admin} = org_with_admin()

      assert {:ok, %Workspace{}} = Workspaces.create_org_workspace(%{name: "\u00C9cole"}, admin)

      for twin <- [
            "E\u0301cole",
            "\u00C9co\u200Ble",
            List.to_string([0x00C9] ++ ~c"cole" ++ [0x200E]),
            List.to_string(~c"\u00C9c" ++ [0x00AD] ++ ~c"ole")
          ] do
        assert {:error, changeset} = Workspaces.create_org_workspace(%{name: twin}, admin)
        assert errors_on(changeset) == %{name: ["has already been taken"]}
      end
    end
  end

  describe "get_workspace/2" do
    setup do
      {organization, admin} = org_with_admin()
      %{organization: organization, admin: admin, workspace: org_workspace_fixture(organization)}
    end

    test "returns a personal workspace to its owner only", %{admin: admin} do
      owner = user_fixture()
      workspace = personal_workspace_fixture(owner)

      assert %Workspace{} = Workspaces.get_workspace(workspace.id, owner)
      assert Workspaces.get_workspace(workspace.id, user_fixture()) == nil
      assert Workspaces.get_workspace(workspace.id, admin) == nil
      assert Workspaces.get_workspace(workspace.id, admin_fixture()) == nil
    end

    test "returns an org workspace to an org-admin with no member row", ctx do
      assert %Workspace{id: id} = Workspaces.get_workspace(ctx.workspace.id, ctx.admin)
      assert id == ctx.workspace.id
    end

    test "returns an org workspace to a member or guest of it", ctx do
      member = org_member(ctx.organization)
      guest = org_member(ctx.organization)
      workspace_member_fixture(ctx.workspace, member, :member)
      workspace_member_fixture(ctx.workspace, guest, :guest)

      assert %Workspace{} = Workspaces.get_workspace(ctx.workspace.id, member)
      assert %Workspace{} = ctx.workspace.id |> to_string() |> Workspaces.get_workspace(guest)
    end

    test "returns not-found to anyone else", ctx do
      {_other_organization, other_admin} = org_with_admin()

      for actor <- [org_member(ctx.organization), user_fixture(), other_admin, admin_fixture()] do
        assert Workspaces.get_workspace(ctx.workspace.id, actor) == nil
      end
    end

    test "returns nil for a missing or malformed id", ctx do
      assert Workspaces.get_workspace(-1, ctx.admin) == nil
      assert Workspaces.get_workspace(0, ctx.admin) == nil
      assert Workspaces.get_workspace("abc", ctx.admin) == nil
      assert Workspaces.get_workspace("#{ctx.workspace.id}abc", ctx.admin) == nil
      assert Workspaces.get_workspace("", ctx.admin) == nil
      assert Workspaces.get_workspace(1.5, ctx.admin) == nil
    end

    test "returns nil rather than raising for nil or an id past the column's range", ctx do
      assert Workspaces.get_workspace(nil, ctx.admin) == nil
      assert Workspaces.get_workspace("99999999999999999999", ctx.admin) == nil
      assert Workspaces.get_workspace(99_999_999_999_999_999_999, ctx.admin) == nil
      assert Workspaces.get_workspace("9223372036854775808", ctx.admin) == nil
    end

    test "accepts the largest id the column holds without raising", ctx do
      assert Workspaces.get_workspace(9_223_372_036_854_775_807, ctx.admin) == nil
      assert Workspaces.get_workspace("9223372036854775807", ctx.admin) == nil
    end

    test "still returns an archived workspace", ctx do
      archived = org_workspace_fixture(ctx.organization, archived_at: DateTime.utc_now(:second))
      assert %Workspace{} = Workspaces.get_workspace(archived.id, ctx.admin)
    end

    test "returns nil to a disabled account, read from the database", ctx do
      member = org_member(ctx.organization)
      workspace_member_fixture(ctx.workspace, member, :member)
      owner = user_fixture()
      personal = personal_workspace_fixture(owner)

      assert Workspaces.get_workspace(ctx.workspace.id, disable(ctx.admin)) == nil
      assert Workspaces.get_workspace(ctx.workspace.id, disable(member)) == nil
      assert Workspaces.get_workspace(personal.id, disable(owner)) == nil
    end
  end

  describe "list_workspaces_for_user/1" do
    setup do
      {organization, admin} = org_with_admin()

      %{
        organization: organization,
        admin: admin,
        alpha: org_workspace_fixture(organization, name: "Alpha"),
        beta: org_workspace_fixture(organization, name: "Beta"),
        archived: org_workspace_fixture(organization, archived_at: DateTime.utc_now(:second))
      }
    end

    test "an org-admin gets every unarchived workspace of their Organization", ctx do
      personal_workspace_fixture(ctx.admin)
      {other_organization, _} = org_with_admin()
      org_workspace_fixture(other_organization)

      assert ctx.admin |> Workspaces.list_workspaces_for_user() |> Enum.map(& &1.id) ==
               [ctx.alpha.id, ctx.beta.id]
    end

    test "a member gets only the unarchived workspaces they have a row on", ctx do
      member = org_member(ctx.organization)
      personal_workspace_fixture(member)
      workspace_member_fixture(ctx.beta, member, :guest)
      workspace_member_fixture(ctx.archived, member, :member)

      assert member |> Workspaces.list_workspaces_for_user() |> Enum.map(& &1.id) == [ctx.beta.id]
    end

    test "sorts names without regard to case", ctx do
      lower = org_workspace_fixture(ctx.organization, name: "alpha two")
      upper = org_workspace_fixture(ctx.organization, name: "Bravo")

      assert ctx.admin |> Workspaces.list_workspaces_for_user() |> Enum.map(& &1.id) ==
               [ctx.alpha.id, lower.id, ctx.beta.id, upper.id]
    end

    test "never returns a personal workspace" do
      user = user_fixture()
      personal_workspace_fixture(user)

      assert Workspaces.list_workspaces_for_user(user) == []
    end

    test "returns nothing to a disabled org-admin or member, read from the database", ctx do
      member = org_member(ctx.organization)
      workspace_member_fixture(ctx.beta, member, :member)
      admin_membership = Kanban.Organizations.get_membership(ctx.admin)
      member_membership = Kanban.Organizations.get_membership(member)

      assert ctx.admin |> disable() |> Workspaces.list_workspaces_for_user() == []
      assert member |> disable() |> Workspaces.list_workspaces_for_user() == []

      # A membership loaded before the account was disabled does not help.
      assert Workspaces.list_workspaces_for_membership(ctx.admin, admin_membership) == []
      assert Workspaces.list_workspaces_for_membership(member, member_membership) == []
    end
  end

  describe "get_member_role/2" do
    test "returns the row's role, or nil without a row" do
      {organization, admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      guest = org_member(organization)
      workspace_member_fixture(workspace, guest, :guest)
      owner = user_fixture()
      personal = personal_workspace_fixture(owner)

      assert Workspaces.get_member_role(workspace, guest) == :guest
      assert Workspaces.get_member_role(workspace.id, guest) == :guest
      assert Workspaces.get_member_role(personal, owner) == :owner
      assert Workspaces.get_member_role(workspace, admin) == nil
    end

    test "takes a string id, and gives nil rather than raising for one that names no row" do
      {organization, _admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      guest = org_member(organization)
      workspace_member_fixture(workspace, guest, :guest)

      assert workspace.id |> Integer.to_string() |> Workspaces.get_member_role(guest) == :guest

      for id <- [nil, "abc", "99999999999999999999", 99_999_999_999_999_999_999, 0, "1.5"] do
        assert Workspaces.get_member_role(id, guest) == nil
      end
    end
  end

  describe "add_member/4" do
    setup do
      {organization, admin} = org_with_admin()
      %{organization: organization, admin: admin, workspace: org_workspace_fixture(organization)}
    end

    test "an org-admin adds a member or guest of the Organization", ctx do
      member = org_member(ctx.organization)
      guest = org_member(ctx.organization)

      assert {:ok, %WorkspaceMember{role: :member}} =
               Workspaces.add_member(ctx.admin, ctx.workspace, member, :member)

      assert {:ok, %WorkspaceMember{role: :guest}} =
               Workspaces.add_member(ctx.admin, ctx.workspace.id, guest, :guest)
    end

    test "refuses users outside the Organization", ctx do
      {other_organization, _} = org_with_admin()

      for user <- [user_fixture(), org_member(other_organization)] do
        assert Workspaces.add_member(ctx.admin, ctx.workspace, user, :member) ==
                 {:error, :not_in_organization}
      end
    end

    test "refuses the owner role and unknown roles", ctx do
      user = org_member(ctx.organization)

      for role <- [:owner, :admin, "member"] do
        assert Workspaces.add_member(ctx.admin, ctx.workspace, user, role) ==
                 {:error, :invalid_role}
      end
    end

    test "refuses an actor who is not an org-admin of the workspace's Organization", ctx do
      user = org_member(ctx.organization)
      {_other_organization, other_admin} = org_with_admin()

      for actor <- [org_member(ctx.organization), other_admin, admin_fixture()] do
        assert Workspaces.add_member(actor, ctx.workspace, user, :member) ==
                 {:error, :unauthorized}
      end
    end

    test "re-reads the workspace instead of trusting the struct", ctx do
      {other_organization, other_admin} = org_with_admin()
      user = org_member(other_organization)
      forged = %{ctx.workspace | organization_id: other_organization.id}

      assert Workspaces.add_member(other_admin, forged, user, :member) == {:error, :unauthorized}
    end

    test "refuses a personal workspace and a missing one", ctx do
      user = org_member(ctx.organization)
      personal = personal_workspace_fixture(user_fixture())

      assert Workspaces.add_member(ctx.admin, personal, user, :member) == {:error, :unauthorized}
      assert Workspaces.add_member(ctx.admin, -1, user, :member) == {:error, :unauthorized}
    end

    test "refuses a new member on an archived workspace", ctx do
      user = org_member(ctx.organization)

      archived =
        org_workspace_fixture(ctx.organization, %{archived_at: DateTime.utc_now(:second)})

      assert Workspaces.add_member(ctx.admin, archived, user, :member) == {:error, :archived}
      assert Workspaces.get_member_role(archived, user) == nil
    end

    test "the archived refusal comes after the admin check", ctx do
      user = org_member(ctx.organization)

      archived =
        org_workspace_fixture(ctx.organization, %{archived_at: DateTime.utc_now(:second)})

      member = org_member(ctx.organization)

      assert Workspaces.add_member(member, archived, user, :member) == {:error, :unauthorized}
    end

    test "takes a string id, and refuses one that cannot name a row without raising", ctx do
      user = org_member(ctx.organization)

      assert {:ok, %WorkspaceMember{}} =
               Workspaces.add_member(ctx.admin, Integer.to_string(ctx.workspace.id), user, :guest)

      for id <- [nil, "abc", "99999999999999999999", 99_999_999_999_999_999_999, "-3"] do
        assert Workspaces.add_member(ctx.admin, id, user, :member) == {:error, :unauthorized}
      end
    end

    test "adding an existing member again is a changeset error", ctx do
      user = org_member(ctx.organization)
      workspace_member_fixture(ctx.workspace, user, :member)

      assert {:error, %Ecto.Changeset{}} =
               Workspaces.add_member(ctx.admin, ctx.workspace, user, :guest)
    end
  end

  describe "update_member_role/4" do
    setup do
      {organization, admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      user = org_member(organization)
      workspace_member_fixture(workspace, user, :member)
      %{organization: organization, admin: admin, workspace: workspace, user: user}
    end

    test "an org-admin changes a member's role", ctx do
      assert {:ok, %WorkspaceMember{role: :guest}} =
               Workspaces.update_member_role(ctx.admin, ctx.workspace, ctx.user, :guest)

      assert Workspaces.get_member_role(ctx.workspace, ctx.user) == :guest
    end

    test "refuses the owner role, a non-admin actor and a missing row", ctx do
      assert Workspaces.update_member_role(ctx.admin, ctx.workspace, ctx.user, :owner) ==
               {:error, :invalid_role}

      assert Workspaces.update_member_role(ctx.user, ctx.workspace, ctx.user, :guest) ==
               {:error, :unauthorized}

      assert Workspaces.update_member_role(
               ctx.admin,
               ctx.workspace,
               org_member(ctx.organization),
               :guest
             ) ==
               {:error, :not_found}
    end

    test "still changes a role on an archived workspace", ctx do
      ctx.workspace |> change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()

      assert {:ok, %WorkspaceMember{role: :guest}} =
               Workspaces.update_member_role(ctx.admin, ctx.workspace, ctx.user, :guest)
    end

    test "refuses an id that cannot name a row without raising", ctx do
      for id <- ["abc", "99999999999999999999", nil] do
        assert Workspaces.update_member_role(ctx.admin, id, ctx.user, :guest) ==
                 {:error, :unauthorized}
      end
    end
  end

  describe "remove_member/3" do
    setup do
      {organization, admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      user = org_member(organization)
      workspace_member_fixture(workspace, user, :guest)
      %{organization: organization, admin: admin, workspace: workspace, user: user}
    end

    test "an org-admin removes a member", ctx do
      assert {:ok, %WorkspaceMember{}} =
               Workspaces.remove_member(ctx.admin, ctx.workspace, ctx.user)

      assert Workspaces.get_member_role(ctx.workspace, ctx.user) == nil
    end

    test "refuses a non-admin actor and a missing row", ctx do
      assert Workspaces.remove_member(ctx.user, ctx.workspace, ctx.user) ==
               {:error, :unauthorized}

      assert Workspaces.remove_member(ctx.admin, ctx.workspace, user_fixture()) ==
               {:error, :not_found}
    end

    test "still removes a member from an archived workspace", ctx do
      ctx.workspace |> change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()

      assert {:ok, %WorkspaceMember{}} =
               Workspaces.remove_member(ctx.admin, ctx.workspace, ctx.user)
    end

    test "takes a string id, and refuses one that cannot name a row without raising", ctx do
      assert Workspaces.remove_member(ctx.admin, "abc", ctx.user) == {:error, :unauthorized}

      assert {:ok, %WorkspaceMember{}} =
               Workspaces.remove_member(ctx.admin, Integer.to_string(ctx.workspace.id), ctx.user)
    end
  end

  describe "Scope.put_workspace/2" do
    test "sets and clears the workspace, and for_user/1 is unchanged" do
      user = user_fixture()
      workspace = personal_workspace_fixture(user)
      scope = Scope.for_user(user)

      assert scope.workspace == nil
      assert scope.user == user
      assert %Scope{workspace: ^workspace} = Scope.put_workspace(scope, workspace)
      assert scope |> Scope.put_workspace(workspace) |> Scope.put_workspace(nil) == scope
    end
  end

  describe "boards.workspace_id" do
    test "is set to the creator's personal workspace, and listing is unchanged" do
      user = user_fixture()
      board = board_fixture(user)

      assert board.workspace_id == Workspaces.get_personal_workspace(user).id
      assert [%Board{id: id}] = Boards.list_boards(user)
      assert id == board.id
    end

    test "is exposed as an association but never cast from user attrs" do
      assert :workspace in Board.__schema__(:associations)
      assert :workspace_id in Board.__schema__(:fields)

      refute Map.has_key?(Board.changeset(%Board{}, %{workspace_id: 1}).changes, :workspace_id)

      refute Map.has_key?(
               Board.owner_changeset(%Board{}, %{workspace_id: 1}).changes,
               :workspace_id
             )
    end

    test "is indexed and references workspaces" do
      %{rows: rows} =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE tablename = 'boards' AND indexdef LIKE '%(workspace_id)%'"
        )

      assert rows != []

      %{rows: [[nullable]]} =
        Repo.query!(
          "SELECT is_nullable FROM information_schema.columns WHERE table_name = 'boards' AND column_name = 'workspace_id'"
        )

      assert nullable == "NO"
    end
  end
end
