defmodule Kanban.Workspaces.Export.Importer.UsersTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Repo
  alias Kanban.Workspaces.Export.Importer.Users

  setup do
    organization = organization_fixture()
    member = user_fixture()
    organization_member_fixture(organization, member, :member)
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    outsider = user_fixture()
    other_org_member = user_fixture()
    organization_member_fixture(organization_fixture(), other_org_member, :org_admin)

    disabled = user_fixture()
    organization_member_fixture(organization, disabled, :member)

    disabled
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
    |> Repo.update!()

    rows = [
      %{"id" => 1, "email" => String.upcase(member.email)},
      %{"id" => 2, "email" => admin.email},
      %{"id" => 3, "email" => outsider.email},
      %{"id" => 4, "email" => other_org_member.email},
      %{"id" => 5, "email" => "nobody-here@example.com"},
      %{"id" => 6, "email" => disabled.email}
    ]

    ctx =
      Users.match(%{rows: %{users: rows}, organization_id: organization.id, skipped: []})

    %{
      ctx: ctx,
      member: member,
      admin: admin,
      outsider: outsider,
      other_org_member: other_org_member,
      disabled: disabled
    }
  end

  test "user/2 maps every enabled account matched by email, ignoring case", t do
    assert Users.user(t.ctx, 1) == t.member.id
    assert Users.user(t.ctx, 2) == t.admin.id
    assert Users.user(t.ctx, 3) == t.outsider.id
    assert Users.user(t.ctx, 4) == t.other_org_member.id
    assert Users.user(t.ctx, 5) == nil
    assert Users.user(t.ctx, 6) == nil
    assert t.ctx.counts == %{users: 4}
  end

  test "attributed/2 maps only matched members of the Organization", t do
    assert Users.attributed(t.ctx, 1) == t.member.id
    assert Users.attributed(t.ctx, 2) == t.admin.id

    for source_id <- [3, 4, 5, 6, 999, nil] do
      assert Users.attributed(t.ctx, source_id) == nil
    end
  end

  test "reports users with no account here and names matched users outside the Organization",
       t do
    assert t.ctx.unmatched_users == Enum.sort(["nobody-here@example.com", t.disabled.email])

    expected =
      [t.outsider.email, t.other_org_member.email]
      |> Enum.sort()
      |> Enum.map(
        &{:users, "#{&1} is not in the Organization; their attributions were left empty"}
      )

    assert Enum.reverse(t.ctx.skipped) == expected
    assert t.ctx.emails[3] == t.outsider.email
  end
end
