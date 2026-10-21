defmodule Kanban.SCIM do
  @moduledoc """
  SCIM 2.0 provisioning for Organizations (W2247).

  An Organization's identity provider manages who belongs to it through
  `/scim/v2`, authenticated by an Organization-scoped bearer token that the
  Organization's org-admins create and revoke in the org console. A token
  never reaches users or workspaces outside its Organization.

    * **Users** (`Kanban.SCIM.Users`): creating a user provisions it through
      `Kanban.SSO.Provisioning.provision_scim/2` (verified domains only, a
      `:member` membership, refusal of a user in another Organization);
      setting `active` to false, or deleting it, deprovisions it
      (`Kanban.SCIM.Lifecycle`, `Kanban.Accounts.deprovision_from_organization/2`);
      setting it back to true re-activates it.
    * **Groups** (`Kanban.SCIM.Groups`): the Organization's workspaces, whose
      membership a PATCH changes.
    * **Tokens** (`Kanban.SCIM.Tokens`): created, listed and revoked by
      org-admins; only their hash is stored.

  Request parsing lives in `Kanban.SCIM.Filter`, `Kanban.SCIM.ListParams`,
  `Kanban.SCIM.Patch` and `Kanban.SCIM.UserMapping`. Every mutation is
  audited with the Organization's id and the token's id, never the token.
  """

  alias Kanban.SCIM.Groups
  alias Kanban.SCIM.Tokens
  alias Kanban.SCIM.Users

  defdelegate list_tokens(organization_id), to: Tokens
  defdelegate change_token(attrs \\ %{}), to: Tokens
  defdelegate create_token(actor, organization_id, attrs), to: Tokens
  defdelegate revoke_token(actor, organization_id, id), to: Tokens
  defdelegate authenticate(presented), to: Tokens

  defdelegate list_users(token, params), to: Users, as: :list
  defdelegate get_user(token, id), to: Users, as: :get
  defdelegate create_user(token, body), to: Users, as: :create
  defdelegate replace_user(token, id, body), to: Users, as: :replace
  defdelegate patch_user(token, id, body), to: Users, as: :patch
  defdelegate delete_user(token, id), to: Users, as: :delete

  defdelegate list_groups(token, params), to: Groups, as: :list
  defdelegate get_group(token, id, params \\ %{}), to: Groups, as: :get
  defdelegate patch_group(token, id, body), to: Groups, as: :patch
end
