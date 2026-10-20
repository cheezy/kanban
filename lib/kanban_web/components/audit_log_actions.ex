defmodule KanbanWeb.AuditLogActions do
  @moduledoc """
  Translated display labels for the audit-log action names, shared by the
  site-admin viewer (`KanbanWeb.Admin.AuditLogLive.Index`) and the
  Organization viewer (`KanbanWeb.OrgLive.AuditLog`).

  The stored action is the atom passed to `Kanban.AuditLog.event/2`, saved as
  a string and declared in `Kanban.Telemetry.Catalog.Families`. This module
  only decides how it is *shown*: the action filter still submits, and the
  exports still carry, the raw action string. An action with no label here,
  such as one an older release recorded, is shown as its raw string.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @doc """
  `{label, value}` option tuples for the action filter, in the order given.
  """
  @spec action_options([String.t()]) :: [{String.t(), String.t()}]
  def action_options(actions) when is_list(actions) do
    Enum.map(actions, &{action_label(&1), &1})
  end

  # Each action is matched literally so gettext can extract every msgid; a
  # runtime-interpolated pgettext/2 would extract nothing.
  @doc """
  Translated label for a stored action string; unknown actions pass through
  unchanged.
  """
  @spec action_label(String.t()) :: String.t()
  def action_label("login_failed"), do: pgettext("audit action", "Sign-in failed")

  def action_label("password_reset_requested"),
    do: pgettext("audit action", "Password reset requested")

  def action_label("api_token_auth_failed"), do: pgettext("audit action", "API token rejected")
  def action_label("api_token_created"), do: pgettext("audit action", "API token created")
  def action_label("api_token_revoked"), do: pgettext("audit action", "API token revoked")

  def action_label("comment_deleted_by_owner"),
    do: pgettext("audit action", "Comment deleted by board owner")

  def action_label("completion_notes_credential_suspected"),
    do: pgettext("audit action", "Possible credential in completion notes")

  def action_label("security_considerations_credential_suspected"),
    do: pgettext("audit action", "Possible credential in security considerations")

  def action_label("two_factor_enabled"),
    do: pgettext("audit action", "Two-factor authentication enabled")

  def action_label("two_factor_disabled"),
    do: pgettext("audit action", "Two-factor authentication disabled")

  def action_label("recovery_codes_regenerated"),
    do: pgettext("audit action", "Recovery codes regenerated")

  def action_label("two_factor_recovery_code_used"),
    do: pgettext("audit action", "Signed in with a recovery code")

  def action_label("login_succeeded_two_factor"),
    do: pgettext("audit action", "Two-factor sign-in succeeded")

  def action_label("two_factor_challenge_failed"),
    do: pgettext("audit action", "Two-factor challenge failed")

  def action_label("permission_denied"), do: pgettext("audit action", "Permission denied")
  def action_label("sudo_mode_entered"), do: pgettext("audit action", "Sudo mode entered")
  def action_label("audit_log_exported"), do: pgettext("audit action", "Audit log exported")

  def action_label("org_audit_log_exported"),
    do: pgettext("audit action", "Organization audit log exported")

  def action_label("organization_created"), do: pgettext("audit action", "Organization created")
  def action_label("organization_updated"), do: pgettext("audit action", "Organization updated")
  def action_label("org_admin_appointed"), do: pgettext("audit action", "Org-admin appointed")
  def action_label("org_admin_removed"), do: pgettext("audit action", "Org-admin removed")

  def action_label("org_member_removed"),
    do: pgettext("audit action", "Organization member removed")

  def action_label("org_member_added"),
    do: pgettext("audit action", "Organization member added")

  def action_label("org_workspace_created"),
    do: pgettext("audit action", "Organization workspace created")

  def action_label("org_workspace_renamed"),
    do: pgettext("audit action", "Organization workspace renamed")

  def action_label("org_workspace_archived"),
    do: pgettext("audit action", "Organization workspace archived")

  def action_label("user_deleted"), do: pgettext("audit action", "Account deleted")

  def action_label("user_delete_refused"),
    do: pgettext("audit action", "Account deletion refused")

  def action_label(action) when is_binary(action), do: action
end
