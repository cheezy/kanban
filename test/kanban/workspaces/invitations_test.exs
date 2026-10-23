defmodule Kanban.Workspaces.InvitationsTest do
  @moduledoc """
  Email invitations to org workspaces and free boards (W2219).

  async: false - some tests switch the global `:plans_enforced` application
  env and the global rate-limit config.
  """
  use Kanban.DataCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.AuditLog
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Invitations
  alias Kanban.Workspaces.WorkspaceMember

  @cap_event [:kanban, :board, :member_cap_reached]
  @audit_event [:kanban, :audit, :org_member_added]

  setup do
    previous = Application.fetch_env(:kanban, :plans_enforced)
    on_exit(fn -> restore_plans_enforced(previous) end)
    Application.put_env(:kanban, :plans_enforced, false)
    :ok
  end

  defp url_fun, do: &"https://example.test/invitations/#{&1}"

  # The plaintext token from the most recent invitation email in the mailbox.
  defp sent_token do
    emails = collect_emails([])
    email = Enum.find(emails, &String.starts_with?(&1.subject, "You're invited to"))
    assert email, "no invitation email was sent"
    [_, token] = Regex.run(~r{/invitations/([A-Za-z0-9_-]+)}, email.html_body)
    token
  end

  defp collect_emails(acc) do
    receive do
      {:email, email} -> collect_emails([email | acc])
    after
      0 -> acc
    end
  end

  defp org_with_admin do
    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    workspace = org_workspace_fixture(organization)
    %{organization: organization, admin: admin, workspace: workspace}
  end

  defp org_board(workspace) do
    board = place_board_in_workspace(workspace)
    Repo.get!(Board, board.id)
  end

  defp invite!(admin, workspace, attrs) do
    {:ok, invitation} =
      Invitations.invite_to_workspace(
        admin,
        workspace,
        Map.merge(%{"role" => "member"}, attrs),
        url_fun()
      )

    {invitation, sent_token()}
  end

  defp board_count(board),
    do: from(bu in BoardUser, where: bu.board_id == ^board.id) |> Repo.aggregate(:count)

  describe "invite_to_workspace/4" do
    setup do: org_with_admin()

    test "stores only the token hash and a 7-day expiry", %{admin: admin, workspace: ws} do
      {invitation, token} = invite!(admin, ws, %{"email" => "new@example.com"})

      assert {:ok, hash} = Invitation.hash_token(token)
      assert invitation.token_hash == hash
      assert invitation.token_hash != token
      refute from(i in Invitation, where: i.token_hash == ^token) |> Repo.exists?()

      expected = DateTime.add(DateTime.utc_now(), 7, :day)
      assert abs(DateTime.diff(invitation.expires_at, expected)) < 60
      assert invitation.role == :member
      assert invitation.invited_by_id == admin.id
    end

    test "refuses everyone but an org-admin of the workspace's Organization",
         %{organization: org, workspace: ws} do
      member = user_fixture()
      organization_member_fixture(org, member)
      other_admin = user_fixture()
      organization_member_fixture(organization_fixture(), other_admin, :org_admin)

      for actor <- [member, other_admin, user_fixture()] do
        assert {:error, :unauthorized} =
                 Invitations.invite_to_workspace(
                   actor,
                   ws,
                   %{"email" => "x@example.com", "role" => "member"},
                   url_fun()
                 )
      end

      assert Repo.aggregate(Invitation, :count) == 0
    end

    test "refuses personal and archived workspaces", %{organization: org, admin: admin} do
      archived = org_workspace_fixture(org, archived_at: DateTime.utc_now(:second))
      personal = personal_workspace_fixture(admin)

      for ws <- [archived, personal] do
        assert {:error, :unauthorized} =
                 Invitations.invite_to_workspace(
                   admin,
                   ws,
                   %{"email" => "x@example.com", "role" => "member"},
                   url_fun()
                 )
      end
    end

    test "validates email and role", %{admin: admin, workspace: ws} do
      for attrs <- [
            %{"email" => "not-an-email", "role" => "member"},
            %{"email" => "a@example.com", "role" => "owner"},
            %{"email" => "a@example.com", "role" => "org_admin"},
            %{"email" => "a@example.com"}
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} =
                 Invitations.invite_to_workspace(admin, ws, attrs, url_fun())
      end
    end

    test "refuses a board from another workspace", %{
      organization: org,
      admin: admin,
      workspace: ws
    } do
      other = org_board(org_workspace_fixture(org))

      assert {:error, :invalid_board} =
               Invitations.invite_to_workspace(
                 admin,
                 ws,
                 %{"email" => "a@example.com", "role" => "guest", "board_id" => "#{other.id}"},
                 url_fun()
               )
    end

    test "a repeated invite renews the pending invitation instead of duplicating it",
         %{admin: admin, workspace: ws} do
      {first, first_token} = invite!(admin, ws, %{"email" => "Dup@Example.com "})

      {second, second_token} =
        invite!(admin, ws, %{"email" => "dup@example.com", "role" => "guest"})

      assert first.id == second.id
      assert second.email == "dup@example.com"
      assert second.role == :guest
      assert first_token != second_token
      assert Repo.aggregate(Invitation, :count) == 1
      assert {:error, :invalid} = Invitations.preview(first_token, nil)
      assert {:ok, :sign_in_required} = Invitations.preview(second_token, nil)
    end

    test "a second pending invitation for the same email is a translated email error",
         %{admin: admin, workspace: ws} do
      {invitation, _token} = invite!(admin, ws, %{"email" => "dup@example.com"})
      {_token, hash} = Invitation.build_token()

      assert {:error, changeset} =
               %{"email" => "DUP@example.com", "role" => "member"}
               |> Invitation.workspace_changeset()
               |> Invitation.put_server_fields(%{
                 workspace_id: ws.id,
                 invited_by_id: admin.id,
                 token_hash: hash,
                 expires_at: invitation.expires_at
               })
               |> Repo.insert()

      assert %{email: ["already has a pending invitation"]} = errors_on(changeset)

      for locale <- ~w(de es fr ja pt zh) do
        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            KanbanWeb.CoreComponents.translate_error({"already has a pending invitation", []})
          end)

        assert translated != "already has a pending invitation", "no #{locale} translation"
      end
    end

    test "sends the email with the accept link", %{admin: admin, workspace: ws} do
      {invitation, token} = invite!(admin, ws, %{"email" => "mail@example.com"})

      # The link in the email carries the token whose hash the row stores.
      assert {:ok, hash} = Invitation.hash_token(token)
      assert Repo.get!(Invitation, invitation.id).token_hash == hash
    end
  end

  describe "invite_to_board/4" do
    test "lets the owner of a personal-workspace board invite, board grant only" do
      owner = user_fixture()
      board = board_fixture(owner)

      assert {:ok, invitation} =
               Invitations.invite_to_board(
                 owner,
                 board,
                 %{"email" => "friend@example.com", "access" => "modify"},
                 url_fun()
               )

      assert invitation.role == nil
      assert invitation.board_id == board.id
      assert invitation.board_access == :modify
      assert invitation.workspace_id == personal_workspace_fixture(owner).id
      assert Invitations.can_invite_to_board?(owner, board)
    end

    test "never grants owner access" do
      owner = user_fixture()
      board = board_fixture(owner)

      for access <- ["owner", "admin", nil] do
        assert {:error, %Ecto.Changeset{}} =
                 Invitations.invite_to_board(
                   owner,
                   board,
                   %{"email" => "friend@example.com", "access" => access},
                   url_fun()
                 )
      end
    end

    test "refuses a non-owner member of a free board" do
      owner = user_fixture()
      board = board_fixture(owner)
      editor = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, editor, :modify, owner)

      assert {:error, :unauthorized} =
               Invitations.invite_to_board(
                 editor,
                 board,
                 %{"email" => "x@example.com", "access" => "read_only"},
                 url_fun()
               )

      refute Invitations.can_invite_to_board?(editor, board)
    end

    test "on an org board an org-admin invites a guest with the board grant" do
      %{admin: admin, workspace: ws} = org_with_admin()
      board = org_board(ws)

      assert {:ok, invitation} =
               Invitations.invite_to_board(
                 admin,
                 board,
                 %{"email" => "guest@example.com", "access" => "read_only"},
                 url_fun()
               )

      assert invitation.role == :guest
      assert invitation.workspace_id == ws.id
      assert invitation.board_access == :read_only
    end

    test "on an org board an explicit owner who is not an org-admin cannot invite" do
      %{organization: org, workspace: ws} = org_with_admin()
      board = org_board(ws)

      owner =
        from(bu in BoardUser, where: bu.board_id == ^board.id, select: bu.user_id) |> Repo.one!()

      owner = Repo.get!(Kanban.Accounts.User, owner)
      organization_member_fixture(org, owner)

      refute Invitations.can_invite_to_board?(owner, board)

      assert {:error, :unauthorized} =
               Invitations.invite_to_board(
                 owner,
                 board,
                 %{"email" => "x@example.com", "access" => "read_only"},
                 url_fun()
               )
    end

    test "refuses up front when the free board is full and plans are enforced" do
      enforce_plans()
      owner = user_fixture()
      board = board_fixture(owner)

      for _ <- 1..2,
          do: {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :read_only, owner)

      assert {:error, :member_cap_reached} =
               Invitations.invite_to_board(
                 owner,
                 board,
                 %{"email" => "x@example.com", "access" => "read_only"},
                 url_fun()
               )
    end
  end

  describe "rate limit" do
    setup do
      previous = Application.get_env(:kanban, Kanban.RateLimit)

      Application.put_env(:kanban, Kanban.RateLimit,
        enabled: true,
        invite: %{scale_ms: 60_000, id_limit: 2}
      )

      on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, previous) end)
      org_with_admin()
    end

    test "blocks an invite flood per inviter", %{admin: admin, workspace: ws} do
      attrs = fn n -> %{"email" => "flood#{n}@example.com", "role" => "member"} end

      assert {:ok, _} = Invitations.invite_to_workspace(admin, ws, attrs.(1), url_fun())
      assert {:ok, _} = Invitations.invite_to_workspace(admin, ws, attrs.(2), url_fun())

      assert {:error, :rate_limited} =
               Invitations.invite_to_workspace(admin, ws, attrs.(3), url_fun())

      assert Repo.aggregate(Invitation, :count) == 2
    end
  end

  describe "accept/2 for a workspace invitation" do
    setup do: org_with_admin()

    test "creates the organization membership, workspace row and board access in one go",
         %{organization: org, admin: admin, workspace: ws} do
      board = org_board(ws)
      invitee = user_fixture(%{email: "joiner@example.com"})

      {invitation, token} =
        invite!(admin, ws, %{
          "email" => "JOINER@example.com",
          "role" => "guest",
          "board_id" => board.id,
          "board_access" => "modify"
        })

      attach_telemetry([@audit_event])

      assert {:ok, %{invitation: accepted, workspace: workspace, board: granted}} =
               Invitations.accept(token, invitee)

      assert accepted.accepted_at
      assert workspace.id == ws.id
      assert granted.id == board.id
      assert Organizations.member?(invitee, org)

      assert Repo.get_by!(WorkspaceMember, workspace_id: ws.id, user_id: invitee.id).role ==
               :guest

      assert Repo.get_by!(BoardUser, board_id: board.id, user_id: invitee.id).access == :modify

      assert [event] = AuditLog.list_events(action: :org_member_added)
      assert event.organization_id == org.id
      assert event.actor_user_id == invitee.id
      assert event.metadata["member_user_id"] == invitee.id
      assert event.metadata["invitation_id"] == invitation.id
      refute Map.has_key?(event.metadata, "email")

      assert_received {:telemetry_event, @audit_event, _measurements, metadata}
      assert metadata.organization_id == org.id
      refute Map.has_key?(metadata, :email)
    end

    test "is single-use", %{admin: admin, workspace: ws} do
      invitee = user_fixture()
      {_invitation, token} = invite!(admin, ws, %{"email" => invitee.email})

      assert {:ok, _} = Invitations.accept(token, invitee)
      assert {:error, :invalid} = Invitations.accept(token, invitee)
    end

    test "an invitation an earlier archive left open is refused on the accept page too",
         %{organization: org, admin: admin, workspace: ws} do
      invitee = user_fixture()
      {_invitation, token} = invite!(admin, ws, %{"email" => invitee.email})
      ws |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()

      assert {:error, :invalid} = Invitations.preview(token, invitee)
      assert {:error, :invalid} = Invitations.accept(token, invitee)
      refute Organizations.member?(invitee, org)
    end

    test "refuses an invitee in another Organization and writes nothing",
         %{organization: org, admin: admin, workspace: ws} do
      invitee = user_fixture()
      organization_member_fixture(organization_fixture(), invitee)
      board = org_board(ws)

      {_invitation, token} =
        invite!(admin, ws, %{"email" => invitee.email, "board_id" => board.id})

      assert {:error, :invalid} = Invitations.preview(token, invitee)
      assert {:error, :invalid} = Invitations.accept(token, invitee)

      refute Organizations.member?(invitee, org)
      refute Repo.get_by(WorkspaceMember, workspace_id: ws.id, user_id: invitee.id)
      refute Repo.get_by(BoardUser, board_id: board.id, user_id: invitee.id)
      assert AuditLog.list_events(action: :org_member_added) == []
      assert from(i in Invitation, select: i.accepted_at) |> Repo.one!() == nil
    end

    test "keeps an org-admin of the same Organization as org-admin and records no audit row",
         %{organization: org, admin: admin, workspace: ws} do
      other_admin = user_fixture()
      organization_member_fixture(org, other_admin, :org_admin)
      {_invitation, token} = invite!(admin, ws, %{"email" => other_admin.email})

      assert {:ok, _} = Invitations.accept(token, other_admin)
      assert Organizations.org_admin?(other_admin, org)
      assert AuditLog.list_events(action: :org_member_added) == []
    end

    test "never lowers an existing workspace role or board access",
         %{organization: org, admin: admin, workspace: ws} do
      member = user_fixture()
      organization_member_fixture(org, member)
      workspace_member_fixture(ws, member, :member)
      board = org_board(ws)
      Repo.insert!(%BoardUser{board_id: board.id, user_id: member.id, access: :modify})

      {_invitation, token} =
        invite!(admin, ws, %{
          "email" => member.email,
          "role" => "guest",
          "board_id" => board.id,
          "board_access" => "read_only"
        })

      assert {:ok, _} = Invitations.accept(token, member)

      assert Repo.get_by!(WorkspaceMember, workspace_id: ws.id, user_id: member.id).role ==
               :member

      assert Repo.get_by!(BoardUser, board_id: board.id, user_id: member.id).access == :modify
      assert AuditLog.list_events(action: :org_member_added) == []
    end

    test "raises a guest invited as a member", %{organization: org, admin: admin, workspace: ws} do
      guest = user_fixture()
      organization_member_fixture(org, guest)
      workspace_member_fixture(ws, guest, :guest)
      {_invitation, token} = invite!(admin, ws, %{"email" => guest.email, "role" => "member"})

      assert {:ok, _} = Invitations.accept(token, guest)
      assert Repo.get_by!(WorkspaceMember, workspace_id: ws.id, user_id: guest.id).role == :member
    end

    test "refuses an email mismatch, expiry, revocation and unknown tokens",
         %{admin: admin, workspace: ws} do
      invitee = user_fixture()
      stranger = user_fixture()

      {_invitation, token} = invite!(admin, ws, %{"email" => invitee.email})
      assert {:error, :invalid} = Invitations.accept(token, stranger)
      assert {:error, :invalid} = Invitations.preview(token, stranger)

      {expired, expired_token} = invite!(admin, ws, %{"email" => "late@example.com"})

      expired_at = :second |> DateTime.utc_now() |> DateTime.add(-1, :second)

      from(i in Invitation, where: i.id == ^expired.id)
      |> Repo.update_all(set: [expires_at: expired_at])

      late = user_fixture(%{email: "late@example.com"})
      assert {:error, :invalid} = Invitations.accept(expired_token, late)

      {revoked, revoked_token} = invite!(admin, ws, %{"email" => "gone@example.com"})
      assert {:ok, _} = Invitations.revoke(admin, revoked.id)
      gone = user_fixture(%{email: "gone@example.com"})
      assert {:error, :invalid} = Invitations.accept(revoked_token, gone)

      for bogus <- ["", "abc", String.duplicate("A", 43), nil, 123, String.duplicate("x", 500)] do
        assert {:error, :invalid} = Invitations.accept(bogus, invitee)
        assert {:error, :invalid} = Invitations.preview(bogus, invitee)
      end

      assert AuditLog.list_events(action: :org_member_added) == []
    end

    test "refuses a disabled or unconfirmed account", %{admin: admin, workspace: ws} do
      invitee = user_fixture()
      {_invitation, token} = invite!(admin, ws, %{"email" => invitee.email})

      from(u in Kanban.Accounts.User, where: u.id == ^invitee.id)
      |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

      assert {:error, :invalid} = Invitations.accept(token, invitee)

      unconfirmed = unconfirmed_user_fixture()
      {_invitation, token} = invite!(admin, ws, %{"email" => unconfirmed.email})

      assert {:error, :invalid} = Invitations.accept(token, unconfirmed)
      refute Organizations.get_membership(unconfirmed)
    end

    test "applies the workspace part when the granted board was deleted",
         %{organization: org, admin: admin, workspace: ws} do
      board = org_board(ws)
      invitee = user_fixture()

      {_invitation, token} =
        invite!(admin, ws, %{"email" => invitee.email, "board_id" => board.id})

      Repo.delete!(board)

      assert {:ok, %{board: nil}} = Invitations.accept(token, invitee)
      assert Organizations.member?(invitee, org)
    end

    test "previews the workspace for a matching user and asks a visitor to sign in",
         %{admin: admin, workspace: ws, organization: org} do
      invitee = user_fixture()
      {_invitation, token} = invite!(admin, ws, %{"email" => invitee.email})

      assert {:ok, :sign_in_required} = Invitations.preview(token, nil)

      assert {:ok, %{target: :workspace, workspace_name: name, organization_name: org_name}} =
               Invitations.preview(token, invitee)

      assert name == ws.name
      assert org_name == org.name
    end
  end

  describe "accept/2 for a board invitation" do
    defp free_board_invitation(extra_members, email) do
      owner = user_fixture()
      board = board_fixture(owner)

      for _ <- List.duplicate(nil, extra_members),
          do: {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :read_only, owner)

      {:ok, invitation} =
        Invitations.invite_to_board(
          owner,
          board,
          %{"email" => email, "access" => "read_only"},
          url_fun()
        )

      %{owner: owner, board: board, invitation: invitation, token: sent_token()}
    end

    test "grants board access only" do
      invitee = user_fixture()
      %{board: board, token: token} = free_board_invitation(0, invitee.email)

      assert {:ok, %{workspace: nil, board: granted}} = Invitations.accept(token, invitee)
      assert granted.id == board.id
      assert Repo.get_by!(BoardUser, board_id: board.id, user_id: invitee.id).access == :read_only
      refute Organizations.get_membership(invitee)

      refute from(m in WorkspaceMember, where: m.user_id == ^invitee.id and m.role != :owner)
             |> Repo.exists?()
    end

    test "refuses a board at the cap while plans are enforced, with one cap event" do
      invitee = user_fixture()
      %{owner: owner, board: board, token: token} = free_board_invitation(1, invitee.email)
      enforce_plans()
      {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :read_only, owner)

      attach_telemetry([@cap_event])
      assert {:error, :member_cap_reached} = Invitations.accept(token, invitee)

      assert_received {:telemetry_event, @cap_event, _m, %{via: :invitation} = metadata}
      assert metadata.actor_user_id == owner.id
      refute_received {:telemetry_event, @cap_event, _m, _metadata}

      refute Repo.get_by(BoardUser, board_id: board.id, user_id: invitee.id)
      assert from(i in Invitation, select: i.accepted_at) |> Repo.one!() == nil
      assert board_count(board) == 3
    end

    test "refuses every repeated Accept while the board stays full, with one cap event each" do
      invitee = user_fixture()
      %{owner: owner, board: board, token: token} = free_board_invitation(1, invitee.email)
      enforce_plans()
      {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :read_only, owner)

      attach_telemetry([@cap_event])

      for _attempt <- 1..2 do
        assert {:error, :member_cap_reached} = Invitations.accept(token, invitee)
        assert_received {:telemetry_event, @cap_event, _m, %{via: :invitation} = metadata}
        assert metadata.actor_user_id == owner.id
      end

      refute_received {:telemetry_event, @cap_event, _m, _metadata}
      refute Repo.get_by(BoardUser, board_id: board.id, user_id: invitee.id)
      assert from(i in Invitation, select: i.accepted_at) |> Repo.one!() == nil
      assert board_count(board) == 3
    end

    test "succeeds at the cap when plans are not enforced" do
      invitee = user_fixture()
      %{board: board, token: token} = free_board_invitation(2, invitee.email)

      assert {:ok, _} = Invitations.accept(token, invitee)
      assert board_count(board) == 4
    end

    test "is refused and revoked once the board has moved into an Organization" do
      invitee = user_fixture()

      %{owner: owner, board: board, invitation: invitation, token: token} =
        free_board_invitation(0, invitee.email)

      organization = organization_fixture()
      organization_member_fixture(organization, owner, :org_admin)
      # Moved without BoardMoves, so the invitation is still open, as an
      # earlier move left some.
      move_board_to_organization(board, organization)

      assert {:error, :invalid} = Invitations.preview(token, invitee)
      assert {:error, :invalid} = Invitations.accept(token, invitee)
      refute Repo.get_by(BoardUser, board_id: board.id, user_id: invitee.id)
      assert Repo.get!(Invitation, invitation.id).revoked_at
      refute Organizations.get_membership(invitee)
    end

    test "is refused once its board was deleted" do
      invitee = user_fixture()
      %{board: board, token: token} = free_board_invitation(0, invitee.email)
      Repo.delete!(board)

      assert {:error, :invalid} = Invitations.preview(token, invitee)
      assert {:error, :invalid} = Invitations.preview(token, nil)
      assert {:error, :invalid} = Invitations.accept(token, invitee)
    end

    test "is a no-op success for an existing member" do
      invitee = user_fixture()
      %{owner: owner, board: board, token: token} = free_board_invitation(0, invitee.email)
      {:ok, _} = Boards.add_user_to_board(board, invitee, :modify, owner)

      assert {:ok, _} = Invitations.accept(token, invitee)
      assert Repo.get_by!(BoardUser, board_id: board.id, user_id: invitee.id).access == :modify
    end
  end

  describe "resend/3, revoke/2 and list_pending/2" do
    setup do: org_with_admin()

    test "an org-admin resends with a new link and revokes", %{admin: admin, workspace: ws} do
      {invitation, old_token} = invite!(admin, ws, %{"email" => "r@example.com"})

      assert {:ok, resent} = Invitations.resend(admin, invitation.id, url_fun())
      new_token = sent_token()
      assert resent.token_hash != invitation.token_hash
      assert {:error, :invalid} = Invitations.preview(old_token, nil)
      assert {:ok, :sign_in_required} = Invitations.preview(new_token, nil)

      assert [%Invitation{id: id}] = Invitations.list_pending(admin, ws)
      assert id == invitation.id

      assert {:ok, revoked} = Invitations.revoke(admin, "#{invitation.id}")
      assert revoked.revoked_at
      assert Invitations.list_pending(admin, ws) == []
      assert {:error, :not_found} = Invitations.revoke(admin, invitation.id)
      assert {:error, :not_found} = Invitations.resend(admin, invitation.id, url_fun())
    end

    test "re-checks the actor on every resend and revoke", %{
      organization: org,
      admin: admin,
      workspace: ws
    } do
      {invitation, _token} = invite!(admin, ws, %{"email" => "r@example.com"})
      member = user_fixture()
      organization_member_fixture(org, member)

      assert {:error, :unauthorized} = Invitations.resend(member, invitation.id, url_fun())
      assert {:error, :unauthorized} = Invitations.revoke(member, invitation.id)
      assert Invitations.list_pending(member, ws) == []

      from(m in OrganizationMember, where: m.user_id == ^admin.id) |> Repo.delete_all()
      assert {:error, :unauthorized} = Invitations.revoke(admin, invitation.id)
      assert {:error, :not_found} = Invitations.revoke(member, "nope")
    end

    test "a board owner resends and revokes a board invitation" do
      owner = user_fixture()
      board = board_fixture(owner)

      {:ok, invitation} =
        Invitations.invite_to_board(
          owner,
          board,
          %{"email" => "b@example.com", "access" => "read_only"},
          url_fun()
        )

      assert {:ok, _} = Invitations.resend(owner, invitation.id, url_fun())
      assert {:error, :unauthorized} = Invitations.revoke(user_fixture(), invitation.id)
      assert {:ok, _} = Invitations.revoke(owner, invitation.id)
    end
  end

  describe "bind_registration/2 and accept_registered/1" do
    setup do: org_with_admin()

    test "joins a new user once they confirm", %{organization: org, admin: admin, workspace: ws} do
      board = org_board(ws)

      {invitation, token} =
        invite!(admin, ws, %{
          "email" => "fresh@example.com",
          "role" => "guest",
          "board_id" => board.id,
          "board_access" => "read_only"
        })

      user = unconfirmed_user_fixture(%{email: "Fresh@example.com"})
      assert :ok = Invitations.bind_registration(token, user)
      assert Repo.get!(Invitation, invitation.id).registered_user_id == user.id

      # Not confirmed yet: refused, and nothing is written.
      assert {:error, :invalid} = Invitations.accept_registered(user)
      refute Organizations.member?(user, org)

      token =
        extract_user_token(fn url ->
          Kanban.Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, user} = Kanban.Accounts.confirm_user(token)

      assert {:ok, _} = Invitations.accept_registered(user)
      assert Organizations.member?(user, org)
      assert Repo.get_by!(WorkspaceMember, workspace_id: ws.id, user_id: user.id).role == :guest
      assert Repo.get_by!(BoardUser, board_id: board.id, user_id: user.id).access == :read_only
      assert :none = Invitations.accept_registered(user)
    end

    test "does not bind a mismatched email or a bad token", %{admin: admin, workspace: ws} do
      {invitation, token} = invite!(admin, ws, %{"email" => "fresh@example.com"})
      other = unconfirmed_user_fixture()

      assert :ok = Invitations.bind_registration(token, other)
      assert :ok = Invitations.bind_registration("garbage", other)
      assert :ok = Invitations.bind_registration(nil, other)
      assert Repo.get!(Invitation, invitation.id).registered_user_id == nil
      assert :none = Invitations.accept_registered(other)
    end
  end
end
