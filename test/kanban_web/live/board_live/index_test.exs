defmodule KanbanWeb.BoardLive.IndexTest do
  @moduledoc """
  Page-level regression for D123: the boards page (TargetsStrip), the
  target-detail page, and the agents delivery-health band must show the SAME
  status for the same delivery target and the same viewer.

  The three surfaces now all anchor status on the viewer's browser-local
  calendar day (via `KanbanWeb.Timezone.browser_timezone/1` +
  `Kanban.Timezone.local_today/1`), so they can no longer split the way the
  original bug did (boards/detail on server UTC, agents on viewer-local).
  """
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks

  describe "cross-page delivery-target status agreement (D123)" do
    setup [:register_and_log_in_user]

    test "boards page, target detail, and agents band agree for a west-of-UTC viewer",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})

      # A target 40 days into a 50-day window with no completed work is at-risk
      # (elapsed ~0.8, work 0.0) for any nearby calendar day, so the assertion
      # is deterministic regardless of the viewer's timezone.
      today = Date.utc_today()
      created_on = Date.add(today, -40)
      target_date = Date.add(today, 10)

      target =
        delivery_target_fixture(user, %{name: "Ships soon", target_date: target_date})

      backdate_target(target, NaiveDateTime.new!(created_on, ~T[00:00:00]))

      goal = goal_on_target(doing, target)
      _incomplete_child = task_fixture(doing, %{parent_id: goal.id})

      # The timezone class that triggered the original split: a viewer west of
      # UTC whose local calendar day can trail the server's UTC day.
      conn = put_connect_params(conn, %{"timezone" => "America/Los_Angeles"})

      {:ok, _boards, boards_html} = live(conn, ~p"/boards")
      assert boards_html =~ "At-risk"

      {:ok, _detail, detail_html} = live(conn, ~p"/targets/#{target.id}")
      assert detail_html =~ "At-risk"

      {:ok, _agents, agents_html} = live(conn, ~p"/agents")
      assert band_count(agents_html, "at-risk") == 1
      assert band_count(agents_html, "on-track") == 0
    end
  end

  describe "archived targets" do
    setup [:register_and_log_in_user]

    test "the header links to the archived targets page", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = delivery_target_fixture(user, %{name: "Active Target"})
      goal_on_target(column, target)

      {:ok, live, _html} = live(conn, ~p"/boards")

      assert has_element?(live, "a[data-archived-targets-link][href='/targets/archived']")
    end

    test "the archived link stays visible when every target is archived",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = delivery_target_fixture(user, %{name: "Gone Target"})
      goal_on_target(column, target)
      archive!(target)

      {:ok, live, _html} = live(conn, ~p"/boards")

      # The link lives in the always-visible header actions, not beside the
      # TargetsStrip — the strip is wrapped in :if={@targets != []}, so a link
      # placed there would disappear exactly when the user has archived
      # everything and most needs a way back to it.
      assert has_element?(live, "a[data-archived-targets-link][href='/targets/archived']")
    end

    test "an archived target no longer appears on the boards page",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      active = delivery_target_fixture(user, %{name: "Still Shipping"})
      goal_on_target(column, active)

      archived = delivery_target_fixture(user, %{name: "Already Shipped"})
      goal_on_target(column, archived)
      archive!(archived)

      {:ok, _live, html} = live(conn, ~p"/boards")

      # The exclusion comes from the is_nil(archived_at) filter W1701 added to
      # list_targets/1, which list_targets_with_status/2 composes.
      assert html =~ "Still Shipping"
      refute html =~ "Already Shipped"
    end
  end

  # Pulls the integer count rendered in the delivery-health band stat tile for a
  # given status marker (on-track / at-risk / missed / complete).
  defp band_count(html, marker) do
    [_, count] =
      Regex.run(
        ~r/data-delivery-health-stat="#{marker}".*?<dd[^>]*>\s*(\d+)\s*<\/dd>/s,
        html
      )

    String.to_integer(count)
  end

  defp goal_on_target(column, target) do
    goal = task_fixture(column, %{type: :goal})
    {:ok, goal} = Tasks.update_task(goal, %{target_id: target.id})
    goal
  end

  # archived_at is only castable through DeliveryTarget.archive_changeset/2, so
  # change/2 stamps it directly, bypassing the cast allow-list.
  defp archive!(%DeliveryTarget{} = target) do
    target
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp backdate_target(%DeliveryTarget{id: id}, %NaiveDateTime{} = at) do
    from(t in DeliveryTarget, where: t.id == ^id)
    |> Repo.update_all(set: [inserted_at: at])
  end
end
