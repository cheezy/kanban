defmodule Kanban.Telemetry.Catalog.Families do
  @moduledoc """
  The two runtime-named event families in `Kanban.Telemetry.Catalog`.

  `[:kanban, :api, action]` and `[:kanban, :audit, action]` build their event
  name from an action atom at runtime. Each action is one tuple in
  `@api_actions` or `@audit_actions` below, and `events/0` turns every tuple
  into a full catalog entry. `Kanban.Telemetry.Catalog` appends these entries
  to its own list; nothing else should call this module.
  """

  # Keys `KanbanWeb.API.TaskActions.emit_telemetry/3` adds to every API event.
  # Kanban.Metrics.UserActivity counts stored kanban.api.task_* events by
  # user_id, so user_id must stay declared.
  @api_common_metadata [:board_id, :user_id, :path, :method]

  # {action, extra metadata keys, description} for [:kanban, :api, action].
  @api_actions [
    {:next_task_fetched, [:task_id, :priority], "An agent fetched its next task."},
    {:task_claimed, [:task_id, :priority, :api_token_id, :specific_task],
     "An agent claimed a task."},
    {:task_completed, [:task_id, :time_spent_minutes], "An agent completed a task."},
    {:task_listed, [:count], "An agent listed tasks."},
    {:comments_listed, [:task_id, :count], "An agent listed a task's comments."},
    {:comment_created, [:task_id], "An agent added a comment to a task."},
    {:task_created, [:task_id], "An agent created a task."},
    {:goal_created, [:goal_id, :child_task_count, :batch, :batch_index],
     "An agent created a goal with its child tasks."},
    {:batch_goals_created, [:total_goals], "An agent created goals in one batch."},
    {:task_create_forbidden_fields_filtered, [:goal_fields, :child_fields],
     "Fields an agent may not set were dropped from a create request."},
    {:task_updated, [:task_id], "An agent updated a task."},
    {:task_update_column_change_forbidden, [:task_id],
     "An agent tried to move a task to another column with an update."},
    {:task_update_forbidden_fields_filtered, [:task_id, :fields],
     "Fields an agent may not set were dropped from an update request."},
    {:task_unclaimed, [:task_id], "An agent released a claimed task."},
    {:task_marked_done, [:task_id, :review_status], "A reviewed task was marked done."},
    {:task_returned_to_doing, [:task_id, :review_status],
     "A reviewed task was sent back to Doing."},
    {:after_goal_reported, [:task_id, :exit_code], "An agent reported its after_goal result."},
    {:task_changed_files_persisted, [:task_id, :file_count],
     "An agent's changed files were stored on a task."},
    {:dependencies_fetched, [:task_id], "An agent fetched a task's dependencies."},
    {:dependents_fetched, [:task_id, :count], "An agent fetched a task's dependents."},
    {:task_tree_fetched, [:task_id], "An agent fetched a task tree."},
    {:after_goal_status_fetched, [:task_id], "An agent fetched a goal's after_goal status."},
    {:mcp_tool_called, [:tool, :is_error], "An agent called an MCP tool."}
  ]

  # {action, metadata keys, description} for [:kanban, :audit, action]. The
  # telemetry copy never carries email, ip or filters; see Kanban.AuditLog.
  @audit_actions [
    {:login_failed, [], "A browser sign-in failed."},
    {:password_reset_requested, [], "A password reset was requested."},
    {:api_token_auth_failed, [:reason], "An API request presented a bad bearer token."},
    {:api_token_created, [:user_id, :board_id, :workspace_id, :organization_id, :token_id],
     "An API token was created."},
    {:api_token_revoked, [:user_id, :token_id, :organization_id], "An API token was revoked."},
    {:comment_deleted_by_owner, [:user_id, :board_id, :task_id, :comment_id, :author_user_id],
     "A board owner deleted someone else's comment."},
    {:completion_notes_credential_suspected, [:task_id, :agent_name],
     "Completion notes looked like they contained a credential."},
    {:security_considerations_credential_suspected, [:task_id, :agent_name],
     "A security consideration in a reviewer result looked like it contained a credential."},
    {:two_factor_enabled, [:user_id], "A user turned on two-factor authentication."},
    {:two_factor_disabled, [:user_id, :method], "A user turned off two-factor authentication."},
    {:recovery_codes_regenerated, [:user_id], "A user regenerated their recovery codes."},
    {:two_factor_recovery_code_used, [:user_id], "A user signed in with a recovery code."},
    {:login_succeeded_two_factor, [:user_id, :method], "A user completed a two-factor sign-in."},
    {:two_factor_challenge_failed, [:user_id, :method], "A two-factor challenge failed."},
    {:permission_denied, [:user_id, :gate, :organization_id],
     "A user was refused access by a permission gate. organization_id is set when the gate knows the Organization, such as a refused API token's."},
    {:sudo_mode_entered, [:user_id], "A recently authenticated user passed a sudo-mode check."},
    {:audit_log_exported, [:user_id, :format], "An admin exported the audit log."},
    {:org_audit_log_exported, [:user_id, :organization_id, :format, :truncated],
     "An org-admin exported their Organization's audit log. user_id is the org-admin; truncated is true when the row cap cut the file."},
    {:organization_created, [:user_id, :organization_id],
     "A site admin created an Organization. user_id is the site admin."},
    {:organization_updated, [:user_id, :organization_id],
     "A site admin changed an Organization's details. user_id is the site admin."},
    {:org_admin_appointed, [:user_id, :organization_id, :member_user_id, :account_created],
     "A site admin made a user an org-admin. user_id is the site admin, member_user_id the appointee. account_created is true when the appointee's account was created for the appointment."},
    {:org_admin_removed, [:user_id, :organization_id, :member_user_id],
     "A site admin removed an org-admin. user_id is the site admin, member_user_id the removed user."},
    {:org_member_removed, [:user_id, :organization_id, :member_user_id],
     "An org-admin removed an ordinary member from their Organization. user_id is the org-admin, member_user_id the removed user."},
    {:org_member_added, [:user_id, :organization_id, :member_user_id, :invitation_id],
     "A user joined an Organization by accepting an invitation. user_id and member_user_id are the joining user, invitation_id the accepted invitation. Recorded only when the acceptance created the membership."},
    {:org_workspace_created, [:user_id, :organization_id, :workspace_id],
     "An org-admin created a workspace for their Organization. user_id is the org-admin."},
    {:org_workspace_renamed, [:user_id, :organization_id, :workspace_id],
     "An org-admin renamed one of their Organization's workspaces. user_id is the org-admin."},
    {:org_workspace_archived, [:user_id, :organization_id, :workspace_id],
     "An org-admin archived one of their Organization's workspaces. user_id is the org-admin."},
    {:organization_policy_updated, [:user_id, :organization_id, :old_values, :new_values],
     "An org-admin changed their Organization's security policy. user_id is the org-admin; old_values and new_values hold only the fields that changed (require_two_factor, two_factor_grace_days, audit_retention_days)."},
    {:retention_purge,
     [:organization_counts, :site_count, :archived_task_count, :saml_count, :failed_steps],
     "The daily retention job ran. organization_counts maps each Organization id with a retention period to the audit events removed; site_count (audit events with no Organization) and archived_task_count are nil when that purge is not configured; saml_count is the expired SAML requests and assertion IDs removed; failed_steps names any step that failed."},
    {:user_deleted, [:user_id, :member_user_id],
     "A site admin deleted an account. user_id is the site admin, member_user_id the deleted account."},
    {:user_delete_refused, [:user_id, :member_user_id, :reason],
     "An account deletion was refused. user_id is the acting user, member_user_id the target account, reason why: unauthorized, cannot_delete_self, user_has_boards, last_admin, last_org_admin or personal_workspace_has_boards."},
    {:account_self_deleted, [:user_id],
     "A user deleted their own account from the account settings. user_id is the deleted account; no email is recorded."},
    {:board_given_to_site_admin, [:user_id, :board_id, :member_user_id],
     "An account deletion left a board that no enabled member could reach, so the earliest enabled site admin was made its owner. user_id is the deleted account, member_user_id the site admin."},
    {:sso_login, [:user_id, :organization_id, :sso_connection_id, :protocol],
     "A user signed in through their Organization's single sign-on connection. protocol is oidc or saml."},
    {:sso_login_refused, [:organization_id, :sso_connection_id, :reason, :protocol],
     "A single sign-on sign-in was refused. protocol is oidc or saml. reason is why: missing_flow, flow_expired, idp_error, state_mismatch, missing_code, connection_unavailable, provider_unreachable, unsafe_url, invalid_discovery, issuer_mismatch, unsupported_algorithms, invalid_jwks, unsupported_client_auth, token_exchange_failed, token_expired, invalid_token, invalid_claims, email_not_verified, domain_not_verified, user_disabled, membership_conflict (the user belongs to another Organization) or plan_required; for SAML also missing_request, request_expired, request_used, response_too_large, invalid_response, unsafe_xml, unsupported_algorithms, status_not_success, destination_mismatch, signature_invalid, audience_mismatch, recipient_mismatch, in_response_to_mismatch, assertion_not_yet_valid, assertion_expired, unsupported_name_id (a transient NameID), assertion_replayed or browser_mismatch (the response was posted from a browser that did not start the sign-in). organization_id and sso_connection_id are set when the connection is known."},
    {:saml_assertion_replayed, [:organization_id, :sso_connection_id],
     "A SAML assertion that had already been accepted was posted again and refused."},
    {:sso_user_provisioned, [:user_id, :organization_id, :sso_connection_id],
     "Single sign-on created an account and an Organization membership for a new user. user_id is the new account."},
    {:sso_account_linked, [:user_id, :organization_id, :sso_connection_id],
     "Single sign-on linked an existing account to its identity provider and made it an Organization member if it was not one."},
    {:organization_domain_verified, [:user_id, :organization_id, :domain],
     "An org-admin verified an email domain for their Organization through its DNS TXT record. user_id is the org-admin."},
    {:sso_connection_updated,
     [
       :user_id,
       :organization_id,
       :sso_connection_id,
       :protocol,
       :enabled,
       :issuer_changed,
       :credentials_changed
     ],
     "An org-admin created or changed their Organization's single sign-on connection. user_id is the org-admin; protocol is oidc or saml; issuer_changed and credentials_changed say whether the issuer (the IdP entity id for SAML) and the client id or secret (the signing certificates for SAML) changed, never their values."},
    {:scim_token_created, [:user_id, :organization_id, :scim_token_id],
     "An org-admin created a SCIM provisioning token for their Organization. user_id is the org-admin; the token value is never recorded."},
    {:scim_token_revoked, [:user_id, :organization_id, :scim_token_id],
     "An org-admin revoked one of their Organization's SCIM provisioning tokens. user_id is the org-admin."},
    {:scim_auth_failed, [:reason],
     "A SCIM request presented a missing, unknown or revoked bearer token. reason is missing_token, not_found or revoked."},
    {:scim_user_provisioned, [:organization_id, :scim_token_id, :member_user_id, :outcome],
     "A SCIM client provisioned a user. outcome is created (a new account managed by the Organization), linked (an existing account joined it) or reactivated (a deprovisioned user was restored)."},
    {:scim_user_updated, [:organization_id, :scim_token_id, :member_user_id, :fields],
     "A SCIM client changed a user's attributes. fields names what changed (name, external_id), never the values."},
    {:scim_user_deprovisioned,
     [
       :organization_id,
       :scim_token_id,
       :member_user_id,
       :reason,
       :disabled,
       :api_credentials_revoked
     ],
     "A SCIM client deprovisioned a user: their Organization membership, workspace memberships and board access there were removed. reason is deactivated or deleted; disabled is true when the account, managed by the Organization, was disabled with every session and API token revoked."},
    {:scim_group_updated,
     [:organization_id, :scim_token_id, :workspace_id, :added_count, :removed_count],
     "A SCIM client changed the members of a Group, one of the Organization's workspaces."}
  ]

  # The API actions whose metrics existed, and were stored in metrics_events,
  # before the catalog generated them. They keep their sum or counter type and
  # stay stored. Kanban.Metrics.UserActivity counts every stored
  # kanban.api.task_* row as admin activity, so storing another task_* action
  # (task_listed, task_updated, ...) would change those counts. Every other API
  # action is a per-request read or write and is shown live only.
  @stored_api_actions [
    :next_task_fetched,
    :task_claimed,
    :task_completed,
    :task_created,
    :task_unclaimed,
    :task_marked_done,
    :task_returned_to_doing
  ]
  @summed_api_actions [:task_created, :task_completed]

  @api_events (for {action, keys, description} <- @api_actions do
                 %{
                   name: [:kanban, :api, action],
                   kind: :event,
                   domain: :api,
                   measurements: [:count],
                   metadata: keys ++ @api_common_metadata,
                   description: description,
                   legacy: true,
                   metrics:
                     if(action in @summed_api_actions,
                       do: [sum: :count],
                       else: [counter: :count]
                     ),
                   persist: action in @stored_api_actions
                 }
               end)

  @audit_events (for {action, keys, description} <- @audit_actions do
                   %{
                     name: [:kanban, :audit, action],
                     kind: :event,
                     domain: :audit,
                     measurements: [:count],
                     metadata: keys,
                     description: description,
                     legacy: true,
                     metrics: [counter: :count],
                     persist: false
                   }
                 end)

  @doc """
  Returns the generated API and audit entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @api_events ++ @audit_events
end
