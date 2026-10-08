defmodule Kanban.Repo.Migrations.ScrubCredentialsFromMetricsEvents do
  @moduledoc """
  Removes credentials that `KanbanWeb.Telemetry.MetricsStorage` stored in
  `metrics_events.metadata` before it filtered them out.

  Phoenix socket telemetry carried the connecting user's session (including
  the raw `user_token`), CSRF tokens and the socket auth token, and a channel
  join carried an inspected `%Phoenix.Socket{}`. This deletes those paths and
  reduces each inspected struct to its module name, matching what the
  sanitiser now stores. It cannot be reversed.
  """

  use Ecto.Migration

  def up do
    Enum.each(scrub_statements(), &execute/1)
  end

  def down, do: :ok

  @doc "The scrub, as SQL statements (also run by the test for this migration)."
  def scrub_statements do
    [
      """
      UPDATE metrics_events
      SET metadata = metadata
        #- '{connect_info,session}'
        #- '{params,_csrf_token}'
        #- '{params,token}'
        #- '{live_socket_id}'
      WHERE (metadata -> 'connect_info') ? 'session'
         OR (metadata -> 'params') ?| array['_csrf_token', 'token']
         OR metadata ? 'live_socket_id'
      """,
      """
      UPDATE metrics_events
      SET metadata = jsonb_set(
        metadata,
        '{socket}',
        to_jsonb(substring(metadata ->> 'socket' from '^%([A-Za-z0-9_.]+)\\{'))
      )
      WHERE metadata ->> 'socket' ~ '^%[A-Za-z0-9_.]+\\{'
      """
    ]
  end
end
