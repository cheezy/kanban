defmodule Kanban.Mobile.Strings.Msgids do
  @moduledoc """
  Lists every string of the `mobile` gettext domain, for
  `Kanban.Mobile.Strings.msgids/0`. It is its own module so that the strings,
  which grow with each app screen, stay apart from the parsing and checking in
  `Kanban.Mobile.Strings`. Add a string here, in the list for its screen, then
  run `MIX_ENV=test mix gettext.extract --merge` and translate it in every
  locale.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @doc """
  The English text of every app string: a msgid, or `{msgid, msgid_plural}`
  for a count. The calls exist so that `mix gettext.extract` writes them, with
  their keys, to `mobile.pot`.

  The status labels and the risk explainer strings are copied from the web's
  default domain. The counts and the `update_required_*` strings are the app's
  own: the Targets, Goals and goal screens of the native apps design (sections
  6.16 to 6.19), its Update required screen (section 7.2) and its Sign in screen
  (section 6.1) have no web page that says the same thing. A `**` pair marks the
  words the app shows in bold; translations keep it around their own words.
  """
  @spec msgids() :: [String.t() | {String.t(), String.t()}]
  def msgids do
    Enum.concat([
      count_msgids(),
      status_msgids(),
      update_required_msgids(),
      sign_in_msgids(),
      shared_view_label_msgids(),
      shared_view_reading_msgids(),
      shared_view_count_msgids(),
      shell_msgids(),
      now_label_msgids(),
      now_card_msgids(),
      now_count_msgids(),
      now_action_msgids(),
      review_queue_msgids()
    ])
  end

  defp count_msgids do
    [
      dpngettext_noop(
        "mobile",
        "target_task_progress",
        "%{done} of %{count} task",
        "%{done} of %{count} tasks"
      ),
      dpngettext_noop("mobile", "target_goal_count", "%{count} goal", "%{count} goals"),
      dpngettext_noop(
        "mobile",
        "targets_at_risk_count",
        "Targets · %{count} at risk",
        "Targets · %{count} at risk"
      ),
      dpngettext_noop(
        "mobile",
        "goals_open_count",
        "Goals · %{count} open",
        "Goals · %{count} open"
      ),
      dpngettext_noop("mobile", "goal_archived_count", "%{count} archived", "%{count} archived")
    ]
  end

  defp status_msgids do
    [
      dpgettext_noop("mobile", "target_status_on_track", "On-track"),
      dpgettext_noop("mobile", "target_status_at_risk", "At-risk"),
      dpgettext_noop("mobile", "target_status_missed", "Missed"),
      dpgettext_noop("mobile", "target_status_complete", "Complete"),
      dpgettext_noop("mobile", "target_risk_title", "Why targets are at risk"),
      dpgettext_noop(
        "mobile",
        "target_risk_slip",
        "Finishing at the current pace would land %{estimate}, after the %{target_date} target. Reduce remaining work or move the target date."
      ),
      dpgettext_noop("mobile", "agent_stuck", "Stuck"),
      dpgettext_noop("mobile", "agent_dormant", "Dormant")
    ]
  end

  defp update_required_msgids do
    [
      dpgettext_noop("mobile", "update_required_title", "Update required"),
      dpgettext_noop(
        "mobile",
        "update_required_message",
        "This version of Stride is no longer supported. Update the app to continue."
      ),
      dpgettext_noop("mobile", "update_required_action", "Open the App Store")
    ]
  end

  defp sign_in_msgids do
    [
      dpgettext_noop("mobile", "sign_in_title", "Stride"),
      dpgettext_noop(
        "mobile",
        "sign_in_tagline",
        "Your agents do the work. Stride tells you when one of them is waiting on you."
      ),
      dpgettext_noop(
        "mobile",
        "sign_in_point_review_face_id",
        "**Review** what an agent finished, verdicts first, and approve with Face ID."
      ),
      dpgettext_noop(
        "mobile",
        "sign_in_point_review_touch_id",
        "**Review** what an agent finished, verdicts first, and approve with Touch ID."
      ),
      dpgettext_noop(
        "mobile",
        "sign_in_point_review_passcode",
        "**Review** what an agent finished, verdicts first, and approve with your passcode."
      ),
      dpgettext_noop(
        "mobile",
        "sign_in_point_unblock",
        "**Unblock** released tasks, expired claims and failed goal hooks."
      ),
      dpgettext_noop(
        "mobile",
        "sign_in_point_ready",
        "**Keep Ready full** so idle agents always have work."
      ),
      dpgettext_noop("mobile", "sign_in_action", "Sign in"),
      dpgettext_noop("mobile", "sign_in_working", "Signing in"),
      dpgettext_noop(
        "mobile",
        "sign_in_note",
        "Opens a secure browser window. Your company sign-in and two-step check work as they do on the web."
      ),
      dpgettext_noop(
        "mobile",
        "sign_in_create_account",
        "New to Stride? Create an account on the web"
      ),
      dpgettext_noop(
        "mobile",
        "sign_in_network_error",
        "Couldn't reach Stride. Check your connection and try again."
      ),
      dpgettext_noop("mobile", "sign_in_failed", "Sign-in didn't finish. Try again."),
      dpgettext_noop(
        "mobile",
        "sign_in_passcode_required",
        "Set a passcode on this device first. Stride uses it to confirm your approvals."
      ),
      dpgettext_noop(
        "mobile",
        "sign_in_locked_title",
        "The app is part of the Organization plan"
      ),
      dpgettext_noop(
        "mobile",
        "sign_in_locked_message",
        "You're signed in, but you aren't in an Organization. Join one, or choose the Organization plan, to review and unblock your agents' work here."
      ),
      dpgettext_noop("mobile", "sign_in_locked_action", "See the plans")
    ]
  end

  # The shared views' strings (W2789), split in two for credo's ABC size. The
  # priority names, the verdict section names and "Review" are copied from the
  # web; the rest are the app's own.
  defp shared_view_label_msgids do
    [
      dpgettext_noop("mobile", "priority_critical", "Critical priority"),
      dpgettext_noop("mobile", "priority_high", "High priority"),
      dpgettext_noop("mobile", "priority_medium", "Medium priority"),
      dpgettext_noop("mobile", "priority_low", "Low priority"),
      dpgettext_noop("mobile", "verdict_section_acceptance_criteria", "Acceptance"),
      dpgettext_noop("mobile", "verdict_section_testing_strategy", "Testing"),
      dpgettext_noop("mobile", "verdict_section_patterns", "Patterns"),
      dpgettext_noop("mobile", "verdict_section_security_considerations", "Security"),
      dpgettext_noop("mobile", "verdict_section_pitfalls", "Pitfalls"),
      dpgettext_noop("mobile", "decision_kind_review", "Review"),
      dpgettext_noop("mobile", "decision_kind_released", "Released by agent"),
      dpgettext_noop("mobile", "decision_kind_claim_expired", "Claim expired"),
      dpgettext_noop("mobile", "decision_kind_hook_failed", "Goal hook failed"),
      dpgettext_noop("mobile", "decision_kind_ready_empty", "Ready is empty"),
      dpgettext_noop("mobile", "goal_hook_failed", "Hook failed")
    ]
  end

  defp shared_view_reading_msgids do
    [
      dpgettext_noop("mobile", "verdict_passed", "%{section} passed"),
      dpgettext_noop("mobile", "verdict_failed", "%{section} failed"),
      dpgettext_noop("mobile", "verdict_not_assessed", "%{section} not assessed"),
      dpgettext_noop("mobile", "progress_no_tasks", "No tasks yet"),
      dpgettext_noop("mobile", "diff_line_added", "Added, line %{line}"),
      dpgettext_noop("mobile", "diff_line_removed", "Removed, line %{line}"),
      dpgettext_noop("mobile", "diff_line_unchanged", "Line %{line}"),
      dpgettext_noop("mobile", "offline_banner", "Offline · showing what you had at %{time}")
    ]
  end

  defp shared_view_count_msgids do
    [
      dpngettext_noop(
        "mobile",
        "progress_done",
        "%{done} of %{count} done",
        "%{done} of %{count} done"
      ),
      dpngettext_noop("mobile", "progress_in_review", "%{count} in review", "%{count} in review"),
      dpngettext_noop(
        "mobile",
        "progress_in_progress",
        "%{count} in progress",
        "%{count} in progress"
      ),
      dpngettext_noop("mobile", "progress_blocked", "%{count} blocked", "%{count} blocked"),
      dpngettext_noop("mobile", "decision_holds_up", "holds up %{count}", "holds up %{count}"),
      dpngettext_noop(
        "mobile",
        "goal_waiting_on_you",
        "%{count} waiting on you",
        "%{count} waiting on you"
      ),
      dpngettext_noop(
        "mobile",
        "goal_progress_fraction",
        "%{done}/%{count}",
        "%{done}/%{count}"
      )
    ]
  end

  # The tab bar and its corner buttons. Every label but "Now" is copied from
  # the web.
  defp shell_msgids do
    [
      dpgettext_noop("mobile", "tab_now", "Now"),
      dpgettext_noop("mobile", "tab_review", "Review"),
      dpgettext_noop("mobile", "tab_boards", "Boards"),
      dpgettext_noop("mobile", "tab_agents", "Agents"),
      dpgettext_noop("mobile", "shell_new_task", "New task"),
      dpgettext_noop("mobile", "shell_settings", "Settings"),
      dpgettext_noop("mobile", "shell_close", "Close")
    ]
  end

  # The Now screen: its filters, states and buttons (W2793).
  defp now_label_msgids do
    [
      dpgettext_noop("mobile", "now_filter_all", "All"),
      dpgettext_noop("mobile", "now_filter_reviews", "Reviews"),
      dpgettext_noop("mobile", "now_filter_problems", "Problems"),
      dpgettext_noop("mobile", "now_filter_ready", "Ready"),
      dpgettext_noop("mobile", "now_sorted", "Sorted by how much each one holds up"),
      dpgettext_noop(
        "mobile",
        "now_empty",
        "Nothing is waiting on you. Your agents have what they need."
      ),
      dpgettext_noop("mobile", "now_loading", "Loading what is waiting on you"),
      dpgettext_noop(
        "mobile",
        "now_offline_nothing",
        "Offline · nothing is saved on this device yet"
      ),
      dpgettext_noop("mobile", "now_needs_connection", "Needs a connection"),
      dpgettext_noop("mobile", "now_open_review", "Open review"),
      dpgettext_noop("mobile", "now_move_to_backlog", "Move to Backlog"),
      dpgettext_noop("mobile", "now_open_on_web", "Open on the web"),
      dpgettext_noop("mobile", "now_view_attempt", "View attempt"),
      dpgettext_noop("mobile", "now_reply", "Reply")
    ]
  end

  # What a Now card says about its decision. The server's own text fills the
  # placeholders.
  defp now_card_msgids do
    [
      dpgettext_noop(
        "mobile",
        "now_claim_expired",
        "Its claim ran out with no update. It is back in Ready for another agent."
      ),
      dpgettext_noop("mobile", "now_hook_failed", "after_goal failed"),
      dpgettext_noop(
        "mobile",
        "now_hook_failed_exit",
        "after_goal failed · exit %{code} · %{duration}"
      ),
      dpgettext_noop("mobile", "now_released_reason", "“%{reason}”"),
      dpgettext_noop("mobile", "now_ready_empty_board", "Ready is empty · %{board}"),
      dpgettext_noop("mobile", "now_header_summary", "%{waiting} · %{held_up}")
    ]
  end

  defp now_count_msgids do
    [
      dpngettext_noop("mobile", "now_held_up", "%{count} task held up", "%{count} tasks held up"),
      dpngettext_noop(
        "mobile",
        "now_agents_working",
        "%{count} agent working",
        "%{count} agents working"
      ),
      dpngettext_noop(
        "mobile",
        "now_claim_expired_agent",
        "%{agent} held it for %{count} minute with no update. It is back in Ready for another agent.",
        "%{agent} held it for %{count} minutes with no update. It is back in Ready for another agent."
      ),
      dpngettext_noop(
        "mobile",
        "now_idle_agents",
        "%{count} agent idle.",
        "%{count} agents idle."
      ),
      dpngettext_noop(
        "mobile",
        "now_backlog_tasks",
        "%{count} task in Backlog to choose from.",
        "%{count} tasks in Backlog to choose from."
      )
    ]
  end

  # What a Now card's actions say: the notices after a move or a reply, the
  # reply sheet and the View attempt sheet (W2794).
  defp now_action_msgids do
    [
      dpgettext_noop("mobile", "now_moved_to_backlog", "Moved to Backlog"),
      dpgettext_noop("mobile", "now_reply_sent", "Reply sent"),
      dpgettext_noop(
        "mobile",
        "now_task_moved",
        "This task has moved since. Now shows where it stands."
      ),
      dpgettext_noop("mobile", "now_not_allowed", "You can no longer change this task."),
      dpgettext_noop("mobile", "now_action_failed", "That did not go through. Try again."),
      dpgettext_noop("mobile", "now_reply_field", "Your reply"),
      dpgettext_noop("mobile", "now_reply_send", "Send"),
      dpgettext_noop("mobile", "now_reply_cancel", "Cancel"),
      dpgettext_noop("mobile", "now_reply_too_long", "A reply can be up to 10,000 characters."),
      dpgettext_noop("mobile", "now_attempt_title", "Last after_goal attempt"),
      dpgettext_noop("mobile", "now_attempt_exit_code", "Exit code"),
      dpgettext_noop("mobile", "now_attempt_duration", "Duration"),
      dpgettext_noop("mobile", "now_attempt_not_reported", "Not reported"),
      dpgettext_noop("mobile", "now_attempt_loading", "Loading the attempt"),
      dpgettext_noop(
        "mobile",
        "now_attempt_unavailable",
        "Could not load the attempt. Try again later."
      ),
      dpgettext_noop(
        "mobile",
        "now_attempt_no_output",
        "The hook's output is not shown on the phone. It can hold secrets or internal paths."
      )
    ]
  end

  # The Review tab's queue: its states, the size of each change and the label
  # on a change too large to approve on a phone (W2795).
  defp review_queue_msgids do
    [
      dpgettext_noop("mobile", "review_queue_loading", "Loading the review queue"),
      dpgettext_noop("mobile", "review_queue_empty", "No reviews are waiting for you."),
      dpgettext_noop("mobile", "review_queue_large", "Large change"),
      dpgettext_noop("mobile", "review_queue_too_large_phone", "Too large to approve on a phone"),
      dpngettext_noop("mobile", "review_queue_waiting", "%{count} waiting", "%{count} waiting"),
      dpngettext_noop("mobile", "review_queue_files", "%{count} file", "%{count} files")
    ]
  end
end
