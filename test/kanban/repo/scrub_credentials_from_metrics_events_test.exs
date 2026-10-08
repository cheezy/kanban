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

  # Production rows carry `params` (a channel join payload) and `connect_info`
  # as JSON arrays too; `#-` raises on an array when the path step is a key,
  # which aborted the first production deploy of this migration.
  test "leaves array-valued params and connect_info alone and still scrubs the row",
       %{migration: migration} do
    id =
      insert(%{
        "connect_info" => [1, 2],
        "params" => ["token", "_csrf_token"],
        "live_socket_id" => "users_sessions:raw-session-token",
        "result" => "ok"
      })

    scrub(migration)

    assert metadata(id) == %{
             "connect_info" => [1, 2],
             "params" => ["token", "_csrf_token"],
             "result" => "ok"
           }
  end

  test "scrubs the session when params is an array", %{migration: migration} do
    id =
      insert(%{
        "connect_info" => %{"session" => %{"user_token" => "raw"}, "peer_data" => true},
        "params" => ["token"]
      })

    scrub(migration)

    assert metadata(id) == %{"connect_info" => %{"peer_data" => true}, "params" => ["token"]}
  end

  test "leaves a top-level array untouched", %{migration: migration} do
    id = insert(["live_socket_id", "token"])

    scrub(migration)

    assert metadata(id) == ["live_socket_id", "token"]
  end

  test "leaves rows without credentials untouched", %{migration: migration} do
    clean = %{"user_id" => "7", "params" => %{"vsn" => "2.0.0"}, "socket" => "Phoenix.Socket"}
    id = insert(clean)

    scrub(migration)

    assert metadata(id) == clean
  end
end
