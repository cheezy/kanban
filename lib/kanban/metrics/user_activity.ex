defmodule Kanban.Metrics.UserActivity do
  @moduledoc """
  Per-user API activity reads aggregated from the `metrics_events` table.

  Extracted from `KanbanWeb.Telemetry.UserActivityPage` (W1705) so the
  aggregation lives in a context rather than the web layer, and so it can be
  reused by an admin page and covered by unit tests. Placed alongside
  `Kanban.Metrics.Workspace` rather than in `Kanban.Accounts` because the data
  source is `metrics_events` — `users` is only joined for the email label — and
  because `Kanban.Accounts` is scoped to user CRUD/auth.

  Two reads back the report:

    * `list_user_activity/1` — one aggregated row per user, with optional
      search, sort, and limit
    * `count_user_activity/1` — the total number of matching users, ignoring
      `:limit`, for pagination

  Both share the same event filter and search filter so the rows and the total
  can never disagree.

  ### Which events count

  Only `metrics_events` rows whose `metric_name` starts with `kanban.api.task_`
  and whose `metadata->>'user_id'` is entirely numeric. That pair of predicates
  is duplicated verbatim in the `metrics_events_task_user_id_int_index` partial
  index (migration `20260323182051`) — changing either here without changing the
  migration silently drops the index from the query plan.

  There is no Ecto schema for `metrics_events`; it is queried by table name.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo

  @type activity_row :: %{
          email: String.t(),
          user_id: integer(),
          total_actions: non_neg_integer(),
          tasks_claimed: non_neg_integer(),
          tasks_completed: non_neg_integer(),
          tasks_created: non_neg_integer(),
          last_activity: NaiveDateTime.t() | DateTime.t() | nil
        }

  @doc """
  Returns one aggregated activity row per user with at least one task event.

  Users with no matching events are absent from the list (the join is inner).

  ## Options

    * `:search` — filters by a case-insensitive match on the user's email.
      `nil` and `""` both mean "no filter". The term is escaped with
      `escape_like/1` and matched with an explicit `ESCAPE '\\'` clause, so
      metacharacters in user input are matched literally.
    * `:sort_by` — one of `:email`, `:total_actions`, `:tasks_claimed`,
      `:tasks_completed`, `:tasks_created`. Any other value sorts by
      `total_actions` descending.
    * `:sort_dir` — `:asc`, or anything else for descending.
    * `:limit` — bounds the number of rows. `nil` (the default) returns every
      matching row.

  ## Examples

      iex> list_user_activity(search: "alice", sort_by: :email, sort_dir: :asc)
      [%{email: "alice@example.com", user_id: 1, total_actions: 3, ...}]

  """
  @spec list_user_activity(keyword()) :: [activity_row()]
  def list_user_activity(opts \\ []) do
    task_events = task_events_subquery()

    base_query =
      from me in subquery(task_events),
        join: u in "users",
        on: me.user_id == u.id,
        group_by: [u.id, u.email],
        select: %{
          email: u.email,
          user_id: u.id,
          total_actions: count(me.id),
          tasks_claimed:
            fragment(
              "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_claimed%')",
              me.metric_name
            ),
          tasks_completed:
            fragment(
              "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_completed%')",
              me.metric_name
            ),
          tasks_created:
            fragment(
              "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_created%')",
              me.metric_name
            ),
          last_activity: max(me.recorded_at)
        }

    base_query
    |> apply_limit(Keyword.get(opts, :limit))
    |> apply_search_filter(Keyword.get(opts, :search))
    |> apply_sort(Keyword.get(opts, :sort_by), Keyword.get(opts, :sort_dir))
    |> Repo.all()
  end

  @doc """
  Returns the number of distinct users matching `:search`.

  Only `:search` is read — `:limit` is deliberately ignored so callers can page
  through a bounded `list_user_activity/1` while still reporting the full total.
  Returns `0` for an empty result.
  """
  @spec count_user_activity(keyword()) :: non_neg_integer()
  def count_user_activity(opts \\ []) do
    task_events = task_events_subquery()

    base_query =
      from me in subquery(task_events),
        join: u in "users",
        on: me.user_id == u.id,
        select: count(u.id, :distinct)

    query = apply_search_filter(base_query, Keyword.get(opts, :search))

    Repo.one(query) || 0
  end

  @doc """
  Escapes the `LIKE`/`ILIKE` metacharacters (`\\`, `%`, `_`) in `s` by
  prefixing each with a backslash, so a search term is matched literally.

  Callers must pair this with an explicit `ESCAPE '\\'` clause on the SQL side
  so Postgres treats the backslash as the escape character regardless of
  session settings.

  ## Examples

      iex> escape_like("50% off")
      "50\\\\% off"

  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(s) when is_binary(s) do
    String.replace(s, ["\\", "%", "_"], &("\\" <> &1))
  end

  defp task_events_subquery do
    from me in "metrics_events",
      where: like(me.metric_name, "kanban.api.task_%"),
      where: fragment("?->>'user_id' ~ '^[0-9]+$'", me.metadata),
      select: %{
        id: me.id,
        metric_name: me.metric_name,
        recorded_at: me.recorded_at,
        user_id: fragment("(?->>'user_id')::integer", me.metadata)
      }
  end

  defp apply_limit(query, nil), do: query

  defp apply_limit(query, limit) when is_integer(limit) do
    from q in query, limit: ^limit
  end

  defp apply_search_filter(query, nil), do: query

  defp apply_search_filter(query, "") do
    apply_search_filter(query, nil)
  end

  defp apply_search_filter(query, search) when is_binary(search) do
    pattern = "%" <> escape_like(search) <> "%"

    from [me, u] in query,
      where: fragment("? ILIKE ? ESCAPE '\\'", u.email, ^pattern)
  end

  defp apply_sort(query, :email, :asc) do
    from [me, u] in query, order_by: [asc: u.email]
  end

  defp apply_sort(query, :email, _) do
    from [me, u] in query, order_by: [desc: u.email]
  end

  defp apply_sort(query, :total_actions, :asc) do
    from [me, u] in query, order_by: [asc: count(me.id)]
  end

  defp apply_sort(query, :total_actions, _) do
    from [me, u] in query, order_by: [desc: count(me.id)]
  end

  defp apply_sort(query, :tasks_claimed, :asc) do
    from [me, u] in query,
      order_by: [
        asc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_claimed%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_claimed, _) do
    from [me, u] in query,
      order_by: [
        desc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_claimed%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_completed, :asc) do
    from [me, u] in query,
      order_by: [
        asc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_completed%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_completed, _) do
    from [me, u] in query,
      order_by: [
        desc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_completed%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_created, :asc) do
    from [me, u] in query,
      order_by: [
        asc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_created%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_created, _) do
    from [me, u] in query,
      order_by: [
        desc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_created%')",
            me.metric_name
          )
      ]
  end

  # Unknown sort fields degrade to the default rather than raising, so an
  # untrusted `sort_by` can never reach the query builder as anything but a
  # matched atom.
  defp apply_sort(query, _, _) do
    # Default to total_actions descending
    from [me, u] in query, order_by: [desc: count(me.id)]
  end
end
