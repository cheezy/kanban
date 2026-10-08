defmodule Kanban.Repo.ScrubCredentialsFromMetricsEventsTest do
  use Kanban.DataCase, async: true

  alias Kanban.Repo

  @migration "priv/repo/migrations/20261008160000_scrub_credentials_from_metrics_events.exs"

  setup_all do
    [{module, _bytecode}] = Code.require_file(@migration)
    %{migration: module}
  end

  defp insert(metadata) do
    {1, [%{id: id}]} =
      Repo.insert_all(
        "metrics_events",
        [
          %{
            metric_name: "phoenix.socket_connected.duration",
            measurement: 1.0,
            metadata: metadata,
            recorded_at: DateTime.utc_now(),
            inserted_at: DateTime.utc_now()
          }
        ],
        returning: [:id]
      )

    id
  end

  defp metadata(id) do
    %{rows: [[metadata]]} = Repo.query!("SELECT metadata FROM metrics_events WHERE id = $1", [id])
    metadata
  end

  defp scrub(migration), do: Enum.each(migration.scrub_statements(), &Repo.query!/1)

  test "removes the session, CSRF and socket tokens and keeps the rest", %{migration: migration} do
    id =
      insert(%{
        "connect_info" => %{
          "session" => %{"user_token" => "raw-session-token", "_csrf_token" => "c"},
          "peer_data" => true
        },
        "params" => %{"_csrf_token" => "c", "token" => "socket-token", "vsn" => "2.0.0"},
        "live_socket_id" => "users_sessions:raw-session-token",
        "result" => "ok"
      })

    scrub(migration)

    assert metadata(id) == %{
             "connect_info" => %{"peer_data" => true},
             "params" => %{"vsn" => "2.0.0"},
             "result" => "ok"
           }
  end

  test "reduces an inspected struct to its module name", %{migration: migration} do
    id =
      insert(%{
        "socket" => "%Phoenix.Socket{assigns: %{}, endpoint: KanbanWeb.Endpoint}",
        "result" => "ok"
      })

    scrub(migration)

    assert metadata(id) == %{"socket" => "Phoenix.Socket", "result" => "ok"}
  end

  test "leaves rows without credentials untouched", %{migration: migration} do
    clean = %{"user_id" => "7", "params" => %{"vsn" => "2.0.0"}, "socket" => "Phoenix.Socket"}
    id = insert(clean)

    scrub(migration)

    assert metadata(id) == clean
  end
end
