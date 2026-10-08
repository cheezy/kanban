defmodule Kanban.Repo.Migrations.ScrubCredentialsFromMetricsEvents do
  @moduledoc """
  Removes credentials that `KanbanWeb.Telemetry.MetricsStorage` stored in
  `metrics_events.metadata` before it filtered them out.

  Phoenix socket telemetry carried the connecting user's session (including
  the raw `user_token`), CSRF tokens and the socket auth token, and a channel
  join carried an inspected `%Phoenix.Socket{}`. This deletes those paths and
  reduces each inspected struct to its module name, matching what the
  sanitiser now stores. It cannot be reversed.

  Each deletion runs only where its parent is a JSON object: `#-` raises when
  a path step names a key but the value there is an array, and production
  rows carry `params` and `connect_info` as arrays as well as objects.
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
      SET metadata = metadata #- '{connect_info,session}'
      WHERE jsonb_typeof(metadata -> 'connect_info') = 'object'
        AND (metadata -> 'connect_info') ? 'session'
      """,
      """
      UPDATE metrics_events
      SET metadata = metadata #- '{params,_csrf_token}' #- '{params,token}'
      WHERE jsonb_typeof(metadata -> 'params') = 'object'
        AND (metadata -> 'params') ?| array['_csrf_token', 'token']
      """,
      """
      UPDATE metrics_events
      SET metadata = metadata - 'live_socket_id'
      WHERE jsonb_typeof(metadata) = 'object'
        AND metadata ? 'live_socket_id'
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
