defmodule Kanban.Workspaces.Invitations do
  @moduledoc """
  Email invitations to Organization workspaces and free boards (W2219, D9).

  Two ways in:

    * `invite_to_workspace/4` — an org-admin invites an email address into one
      of their Organization's workspaces as a `:member` or `:guest`, optionally
      with access to one board in that workspace. Accepting it makes the
      invitee a member of the Organization (one Organization per user).
    * `invite_to_board/4` — from a board's members form. On a board in a
      personal workspace (a free board) only the board's owner may invite, and
      accepting grants board access only, subject to the free-board member cap
      (W2400). On a board in an org workspace only an org-admin may invite, and
      the invitation becomes a workspace invitation with role `:guest` plus the
      board grant. Neither ever grants `:owner` access.

  The inviter's authority is re-read from the database on every invite,
  resend and revoke. Sends and resends are rate-limited per inviter
  (`Kanban.RateLimit`, surface `:invite`). Only a hash of each token is
  stored; the plaintext goes into the email and nowhere else. Inviting an
  address that already has a pending invitation to the same workspace and
  board renews that invitation (new link, new expiry) instead of adding a
  second one.

  Acceptance (`accept/2`, `accept_registered/1`) lives in
  `Kanban.Workspaces.InvitationAcceptance`. Every invalid state — unknown,
  expired, revoked or used token, an email that does not match, an invitee
  in another Organization, a disabled account — is the same `:invalid`, so the
  page can show one message and disclose nothing about the token or the
  invited address. Only a full free board gets its own error,
  `:member_cap_reached`.

  A new user can register from the link: `bind_registration/2` links the
  invitation to the new account when its email matches, and
  `accept_registered/1` accepts it once that account confirms its email.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserNotifier
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.RateLimit
  alias Kanban.Repo
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.InvitationAcceptance
  alias Kanban.Workspaces.InvitationAuthorization
  alias Kanban.Workspaces.Workspace

  @typedoc "Builds the accept link from the plaintext token, e.g. `&url(~p\"/invitations/\#{&1}\")`."
  @type url_fun :: (String.t() -> String.t())

  @type invite_error ::
          :unauthorized
          | :invalid_board
          | :member_cap_reached
          | :rate_limited
          | Ecto.Changeset.t()

  @doc """
  Invites `attrs["email"]` into the org workspace `workspace` with
  `attrs["role"]` (`"member"` or `"guest"`), and, when `attrs["board_id"]`
  names a board in that workspace, `attrs["board_access"]` (`"read_only"`,
  the default, or `"modify"`) on it.

  `actor` must be an enabled org-admin of the workspace's Organization, read
  from the database; anyone else, a personal workspace and an archived one get
  `{:error, :unauthorized}`. An invalid form returns its changeset without
  using up the rate limit. On success the invitation email is sent with
  `url_fun.(token)` as its link.
  """
  @spec invite_to_workspace(User.t(), Workspace.t() | integer(), map(), url_fun()) ::
          {:ok, Invitation.t()} | {:error, invite_error()}
  def invite_to_workspace(%User{} = actor, workspace, attrs, url_fun)
      when is_map(attrs) and is_function(url_fun, 1) do
    actor
    |> InvitationAuthorization.managed_workspace(workspace)
    |> prepare_workspace_invite(attrs)
    |> limited_send(url_fun)
  end

  defp prepare_workspace_invite({:ok, actor, workspace}, attrs) do
    with {:ok, changeset} <- valid(Invitation.workspace_changeset(attrs)),
         {:ok, board} <- InvitationAuthorization.workspace_board(workspace, attrs["board_id"]) do
      fields = workspace_fields(actor, workspace, board, attrs["board_access"])
      {:ok, changeset, fields, {actor, workspace, board}}
    end
  end

  defp prepare_workspace_invite(error, _attrs), do: error

  defp workspace_fields(actor, workspace, nil, _access),
    do: %{workspace_id: workspace.id, board_id: nil, board_access: nil, invited_by_id: actor.id}

  defp workspace_fields(actor, workspace, board, access) do
    %{
      workspace_id: workspace.id,
      board_id: board.id,
      board_access: board_access(access),
      invited_by_id: actor.id
    }
  end

  @doc """
  Invites `attrs["email"]` to `board` with `attrs["access"]` (`"read_only"` or
  `"modify"`; anything else, `"owner"` included, is a changeset error).

  On a board in a personal workspace `actor` must hold the board's own owner
  row, and a board at its free-plan member cap is refused with
  `{:error, :member_cap_reached}` before anything is sent. On a board in an
  org workspace `actor` must be an org-admin of its Organization, and the
  invitation is a workspace invitation with role `:guest` plus the board
  grant. Anyone else gets `{:error, :unauthorized}`.
  """
  @spec invite_to_board(User.t(), Board.t() | integer(), map(), url_fun()) ::
          {:ok, Invitation.t()} | {:error, invite_error()}
  def invite_to_board(%User{} = actor, board, attrs, url_fun)
      when is_map(attrs) and is_function(url_fun, 1) do
    actor
    |> InvitationAuthorization.invitable_board(board)
    |> prepare_board_invite(attrs)
    |> limited_send(url_fun)
  end

  defp prepare_board_invite({:ok, actor, board, workspace}, attrs) do
    with {:ok, changeset} <- valid(board_changeset(attrs)),
         :ok <- check_board_room(board, workspace) do
      {:ok, changeset, board_fields(actor, board, workspace), {actor, workspace, board}}
    end
  end

  defp prepare_board_invite(error, _attrs), do: error

  defp board_changeset(attrs),
    do:
      Invitation.board_changeset(%{"email" => attrs["email"], "board_access" => attrs["access"]})

  # A board in an org workspace is invited to as a guest of that workspace.
  defp board_fields(actor, board, workspace) do
    %{
      workspace_id: workspace.id,
      board_id: board.id,
      role: if(workspace.personal, do: nil, else: :guest),
      invited_by_id: actor.id
    }
  end

  @doc """
  True when `user` may invite people to `board` by email: the board's owner
  for a board in a personal workspace, an org-admin of its Organization for a
  board in an org workspace. Read from the database.
  """
  @spec can_invite_to_board?(User.t(), Board.t() | integer() | nil) :: boolean()
  def can_invite_to_board?(%User{} = user, board) do
    match?(
      {:ok, _actor, _board, _workspace},
      InvitationAuthorization.invitable_board(user, board)
    )
  end

  def can_invite_to_board?(_user, _board), do: false

  @doc """
  Sends a pending invitation again with a new link and a new #{Invitation.validity_days()}-day
  expiry; the old link stops working. `actor` must still be allowed to send
  it (see `invite_to_workspace/4` and `invite_to_board/4`). An accepted or
  revoked invitation, or an id `actor` may not manage, gives
  `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  @spec resend(User.t(), integer() | String.t(), url_fun()) ::
          {:ok, Invitation.t()} | {:error, :unauthorized | :not_found | :rate_limited}
  def resend(%User{} = actor, invitation_id, url_fun) when is_function(url_fun, 1) do
    with {:ok, actor, invitation, workspace, board} <-
           InvitationAuthorization.managed_invitation(actor, invitation_id),
         :ok <- rate_limit(actor) do
      renew_and_send(invitation, url_fun, {actor, workspace, board})
    end
  end

  defp renew_and_send(invitation, url_fun, {actor, _workspace, _board} = sender) do
    {token, hash} = Invitation.build_token()

    invitation
    |> Invitation.renew_changeset(%{
      token_hash: hash,
      expires_at: Invitation.expires_at_from(DateTime.utc_now()),
      invited_by_id: actor.id
    })
    |> Repo.update()
    |> case do
      {:ok, invitation} -> send_email(invitation, token, url_fun, sender)
      {:error, _changeset} -> {:error, :not_found}
    end
  end

  @doc """
  Revokes a pending invitation, so its link stops working. `actor` must still
  be allowed to send it.
  """
  @spec revoke(User.t(), integer() | String.t()) ::
          {:ok, Invitation.t()} | {:error, :unauthorized | :not_found}
  def revoke(%User{} = actor, invitation_id) do
    with {:ok, _actor, invitation, _workspace, _board} <-
           InvitationAuthorization.managed_invitation(actor, invitation_id) do
      invitation
      |> Invitation.revoke_changeset(DateTime.utc_now())
      |> Repo.update()
      |> case do
        {:ok, invitation} -> {:ok, invitation}
        {:error, _changeset} -> {:error, :not_found}
      end
    end
  end

  @doc """
  Lists the workspace's open invitations (not accepted or revoked, expired
  ones included, since a resend renews them), newest first, with `:board` and
  `:invited_by` preloaded. Empty unless `actor` may manage the workspace.
  """
  @spec list_pending(User.t(), Workspace.t() | integer()) :: [Invitation.t()]
  def list_pending(%User{} = actor, workspace) do
    case InvitationAuthorization.managed_workspace(actor, workspace) do
      {:ok, _actor, %Workspace{id: workspace_id}} ->
        from(i in Invitation.open_query(),
          where: i.workspace_id == ^workspace_id,
          order_by: [desc: i.inserted_at, desc: i.id],
          preload: [:board, :invited_by]
        )
        |> Repo.all()

      {:error, _reason} ->
        []
    end
  end

  @doc "A changeset for the workspace invite form, for `phx-change` feedback."
  @spec change_workspace_invitation(map()) :: Ecto.Changeset.t()
  def change_workspace_invitation(attrs \\ %{}), do: Invitation.workspace_changeset(attrs)

  @doc """
  Looks at an invitation link without accepting it, for the accept page.

  Returns `{:ok, :sign_in_required}` for a valid link when nobody is signed
  in (disclosing nothing about the invitation), `{:ok, details}` with the
  workspace, Organization and board names when `user` may accept it, and
  `{:error, :invalid}` for every other state.
  """
  @spec preview(term(), User.t() | nil) ::
          {:ok, :sign_in_required | map()} | {:error, :invalid}
  def preview(token, user) do
    with {:ok, hash} <- Invitation.hash_token(token),
         %Invitation{} = invitation <- get_by_hash(hash),
         true <- Invitation.pending?(invitation, DateTime.utc_now()) do
      preview_for(invitation, user)
    else
      _invalid -> {:error, :invalid}
    end
  end

  # A board-only invitation whose board was deleted can never be accepted.
  defp preview_for(%Invitation{role: nil, board_id: nil}, _user), do: {:error, :invalid}
  defp preview_for(_invitation, nil), do: {:ok, :sign_in_required}

  defp preview_for(%Invitation{} = invitation, %User{} = user) do
    if InvitationAcceptance.acceptable_by?(invitation, user) do
      {:ok,
       %{
         target: if(invitation.role, do: :workspace, else: :board),
         workspace_name: if(invitation.role, do: invitation.workspace.name),
         organization_name: organization_name(invitation),
         board_name: invitation.board && invitation.board.name
       }}
    else
      {:error, :invalid}
    end
  end

  @doc """
  Accepts the invitation `token` names for `user`. See
  `Kanban.Workspaces.InvitationAcceptance.run/2`.
  """
  @spec accept(term(), User.t()) ::
          {:ok, map()} | {:error, :invalid | :member_cap_reached}
  def accept(token, %User{} = user) do
    case Invitation.hash_token(token) do
      {:ok, hash} -> InvitationAcceptance.run(user, token_hash: hash)
      :error -> {:error, :invalid}
    end
  end

  @doc """
  Links the invitation `token` names to `user`, an account just registered
  from its link, when the invitation is pending, its email matches `user`'s
  and no account is linked yet. Always returns `:ok`, so registering looks the
  same whether or not the link was valid.
  """
  @spec bind_registration(term(), User.t()) :: :ok
  def bind_registration(token, %User{} = user) do
    with {:ok, hash} <- Invitation.hash_token(token),
         %Invitation{registered_user_id: nil} = invitation <- get_by_hash(hash),
         true <- Invitation.pending?(invitation, DateTime.utc_now()),
         true <- Invitation.email_matches?(invitation, user.email) do
      invitation |> Invitation.register_changeset(user.id) |> Repo.update()
    end

    :ok
  end

  @doc """
  Accepts the newest open invitation linked to `user` by
  `bind_registration/2`, once `user` has confirmed their email. Returns
  `:none` when there is none, else the result of the acceptance.
  """
  @spec accept_registered(User.t()) :: :none | {:ok, map()} | {:error, atom()}
  def accept_registered(%User{id: user_id} = user) do
    from(i in Invitation.open_query(),
      where: i.registered_user_id == ^user_id,
      order_by: [desc: i.inserted_at, desc: i.id],
      limit: 1,
      select: i.id
    )
    |> Repo.one()
    |> case do
      nil -> :none
      invitation_id -> InvitationAcceptance.run(user, id: invitation_id)
    end
  end

  # -- inviting ---------------------------------------------------------------

  defp valid(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp valid(changeset), do: {:error, Map.put(changeset, :action, :insert)}

  # The rate limit is checked last, so a refused or invalid invite does not
  # use it up.
  defp limited_send({:ok, changeset, fields, {actor, _workspace, _board} = sender}, url_fun) do
    with :ok <- rate_limit(actor), do: save_and_send(changeset, fields, url_fun, sender)
  end

  defp limited_send({:error, _reason} = error, _url_fun), do: error

  defp rate_limit(%User{id: actor_id}) do
    case RateLimit.check(:invite, identity: "user:#{actor_id}") do
      :ok -> :ok
      {:error, {:rate_limited, _retry_after_ms}} -> {:error, :rate_limited}
    end
  end

  # An open invitation to the same workspace, email and board is renewed under
  # a row lock; otherwise a new one is inserted. Two first invites racing are
  # caught by the pending-invitation unique index as a changeset error.
  defp save_and_send(changeset, fields, url_fun, sender) do
    {token, hash} = Invitation.build_token()

    fields =
      Map.merge(fields, %{
        token_hash: hash,
        expires_at: Invitation.expires_at_from(DateTime.utc_now())
      })

    email = Ecto.Changeset.get_field(changeset, :email)

    fn -> upsert(changeset, fields, email) end
    |> Repo.transact()
    |> case do
      {:ok, invitation} -> send_email(invitation, token, url_fun, sender)
      {:error, _reason} = error -> error
    end
  end

  defp upsert(changeset, fields, email) do
    case lock_open(fields.workspace_id, email, fields.board_id) do
      nil ->
        changeset |> Invitation.put_server_fields(fields) |> Repo.insert()

      %Invitation{} = existing ->
        renewal =
          fields
          |> Map.put_new(:role, Ecto.Changeset.get_field(changeset, :role))
          |> Map.put_new(:board_access, Ecto.Changeset.get_field(changeset, :board_access))

        existing |> Invitation.renew_changeset(renewal) |> Repo.update()
    end
  end

  defp lock_open(workspace_id, email, board_id) do
    Invitation.open_query()
    |> where([i], i.workspace_id == ^workspace_id and i.email == ^email)
    |> where_board(board_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp where_board(query, nil),
    do: where(query, [i], is_nil(i.board_id) and is_nil(i.board_access))

  defp where_board(query, board_id), do: where(query, [i], i.board_id == ^board_id)

  defp send_email(%Invitation{} = invitation, token, url_fun, {actor, workspace, board}) do
    details = delivery_details(actor, workspace, board)

    {:ok, _email} =
      UserNotifier.deliver_workspace_invitation(invitation.email, details, url_fun.(token))

    {:ok, invitation}
  end

  defp delivery_details(actor, %Workspace{} = workspace, %Board{} = board)
       when workspace.personal do
    %{inviter_name: actor.name, target_name: board.name, target: :board}
  end

  defp delivery_details(actor, %Workspace{} = workspace, _board) do
    %{inviter_name: actor.name, target_name: workspace.name, target: :workspace}
  end

  defp board_access("modify"), do: :modify
  defp board_access(_read_only_or_missing), do: :read_only

  defp check_board_room(%Board{} = board, %Workspace{personal: true}) do
    if Boards.member_cap_status(board).reached?, do: {:error, :member_cap_reached}, else: :ok
  end

  defp check_board_room(_board, _workspace), do: :ok

  # -- helpers ----------------------------------------------------------------

  defp get_by_hash(hash) do
    Invitation
    |> Repo.get_by(token_hash: hash)
    |> Repo.preload([:board, workspace: :organization])
  end

  defp organization_name(%Invitation{role: nil}), do: nil

  defp organization_name(%Invitation{workspace: %Workspace{organization: %{name: name}}}),
    do: name

  defp organization_name(_invitation), do: nil
end
