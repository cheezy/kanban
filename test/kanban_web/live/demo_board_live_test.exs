defmodule KanbanWeb.DemoBoardLiveTest do
  # Not async: one test sets the :demo_board_tick_ms application env.
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.DemoBoard
  alias KanbanWeb.DemoBoardLive

  @locales ~w(de en es fr ja pt zh)

  # Sends the tick the view is waiting for, as its timer would.
  defp tick(view) do
    token = :sys.get_state(view.pid).socket.assigns.tick_token
    send(view.pid, {:tick, token})
    render(view)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp card_in?(view, card, column),
    do: has_element?(view, ~s([data-demo-column="#{column}"] [data-demo-card="#{card}"]))

  # The page renders in the marketing layout for everyone: the marketing header
  # and footer, no app shell or SideNav, and one sign-up call to action.
  defp assert_marketing_page(conn) do
    document = conn |> get(~p"/demo") |> html_response(200) |> LazyHTML.from_document()

    assert count(document, ".stride-marketing [data-demo-board].stride-screen") == 1
    assert count(document, ".stride-marketing footer") == 1
    assert count(document, "#app-shell") == 0
    assert count(document, "#app-sidebar") == 0
    refute LazyHTML.text(document) =~ "Go to my boards"

    assert_sign_up_cta(conn)
  end

  defp assert_sign_up_cta(conn) do
    {:ok, view, _html} = live(conn, ~p"/demo")
    assert has_element?(view, ~s([data-demo-cta][href="/users/register"]), "Start now")
    refute render(view) =~ "Go to my boards"
  end

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  describe "GET /demo" do
    test "/demo renders the sample board without signing in", %{conn: conn} do
      html = conn |> get(~p"/demo") |> html_response(200)

      assert html =~ "data-demo-board"

      for column <- DemoBoard.columns() do
        assert html =~ ~s(data-demo-column="#{column}")
      end

      {:ok, view, _html} = live(conn, ~p"/demo")
      assert card_in?(view, "W101", :ready)
      assert card_in?(view, "W104", :doing)
      assert has_element?(view, "[data-demo-cta]", "Start now")
    end

    test "/demo renders without signing in", %{conn: conn} do
      document = conn |> get(~p"/demo") |> html_response(200) |> LazyHTML.from_document()

      head_attr = fn selector, attribute ->
        document |> LazyHTML.query("head " <> selector) |> LazyHTML.attribute(attribute)
      end

      assert [description] = head_attr.(~s(meta[name="description"]), "content")
      assert description == DemoBoardLive.meta_description()
      assert String.length(description) in 70..160
      assert head_attr.(~s(meta[name="robots"]), "content") == []

      assert head_attr.(~s(link[rel="canonical"]), "href") == [
               KanbanWeb.Endpoint.url() <> "/demo"
             ]

      assert document |> LazyHTML.query("title") |> LazyHTML.text() =~ "Live demo board"
    end

    test "/demo renders in the marketing layout, with no app shell or SideNav", %{conn: conn} do
      assert_marketing_page(conn)
    end

    test "a signed-in visitor sees the same page, with no SideNav", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert_marketing_page(conn)
    end

    test "the sitemap lists /demo" do
      assert "/demo" in KanbanWeb.SeoXML.public_paths()
    end
  end

  describe "the replay" do
    test "a tick moves the next scripted card to its next column", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")
      assert has_element?(view, "[data-demo-activity]", "Waiting for the first agent")

      tick(view)

      assert card_in?(view, "W101", :doing)
      refute card_in?(view, "W101", :ready)
      assert has_element?(view, ~s([data-demo-event="W101"]), "Claude claimed W101")
      assert has_element?(view, ~s([data-demo-event="W101"] code), "before_doing")

      assert has_element?(
               view,
               ~s([data-demo-event="W101"] [data-demo-result="passed"]),
               "passed"
             )
    end

    test "a failing hook is shown and the card stays where it is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")

      for _ <- 1..4, do: tick(view)

      assert card_in?(view, "W101", :doing)
      assert has_element?(view, ~s([data-demo-result="failed"]), "failed")
    end

    test "a column header counts its task cards, not the goal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")

      assert card_in?(view, "G10", :ready)
      assert has_element?(view, ~s([data-demo-column="ready"] [data-column-count]), "2")
      refute has_element?(view, ~s([data-demo-column="ready"] [data-column-count]), "3")
    end

    test "a live patch to /demo changes nothing and keeps the view alive", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")
      tick(view)
      html = render(view)

      render_patch(view, ~p"/demo")

      assert Process.alive?(view.pid)
      assert render(view) == html
      assert assigns(view).index == 1
    end

    test "a stale tick changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")
      html = render(view)

      send(view.pid, {:tick, make_ref()})

      assert render(view) == html
      assert assigns(view).index == 0
    end

    test "the script loops back to the start after its last step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")
      steps = length(DemoBoard.script())

      for _ <- 1..steps, do: tick(view)

      assert assigns(view).index == steps
      assert card_in?(view, "W101", :done)
      assert card_in?(view, "W103", :review)

      tick(view)

      assert assigns(view).index == 0
      assert assigns(view).board == DemoBoard.initial_board()
      assert card_in?(view, "W101", :ready)
      assert has_element?(view, "[data-demo-activity]", "Waiting for the first agent")

      tick(view)
      assert card_in?(view, "W101", :doing)
    end
  end

  describe "the goal" do
    test "the goal card renders and moves with its first claimed child", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")

      assert card_in?(view, "G10", :ready)
      assert has_element?(view, ~s([data-demo-card="G10"]), "Get the app ready for launch")
      assert has_element?(view, ~s([data-demo-card="G10"]), "GOAL")
      assert has_element?(view, ~s([data-demo-card="G10"]), "2/5")
      assert has_element?(view, ~s([data-demo-card="W101"] [data-goal-chip]), "G10")
      refute has_element?(view, ~s([data-demo-card="W103"] [data-goal-chip]))

      tick(view)

      assert card_in?(view, "G10", :doing)
      refute card_in?(view, "G10", :ready)
    end

    test "the goals strip renders the goal's progress, without links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")

      assert has_element?(view, "[data-demo-goals]", "Active goals")
      assert has_element?(view, "[data-demo-goals] [data-goal-pill]", "G10")
      assert has_element?(view, "[data-demo-goals] [data-goal-pill]", "2/5")
      refute has_element?(view, "[data-demo-goals] a")
      refute has_element?(view, "[data-demo-goals]", "unpromoted")

      for _ <- 1..9, do: tick(view)

      assert card_in?(view, "G10", :done)
      assert has_element?(view, "[data-demo-goals] [data-goal-pill]", "5/5")

      tick(view)
      tick(view)

      assert assigns(view).index == 0
      assert has_element?(view, "[data-demo-goals] [data-goal-pill]", "2/5")
    end
  end

  describe "read-only" do
    test "no click, drag or form on the demo changes any data", %{conn: conn} do
      tasks_before = Repo.aggregate(Task, :count)
      boards_before = Repo.aggregate(Board, :count)
      {:ok, view, _html} = live(conn, ~p"/demo")
      html = render(view)

      for selector <- ~w([phx-click] form [phx-hook] [draggable] [phx-submit] [phx-change]) do
        refute has_element?(view, "[data-demo-board] " <> selector)
      end

      for event <-
            ~w(move_task move_task_to_ready view_task promote_goal_to_ready delete_task archive_task move_column open_goal save) do
        render_hook(view, event, %{"id" => "W101", "task_id" => 1, "column_id" => 2})
        assert render(view) == html
      end

      assert Process.alive?(view.pid)
      assert assigns(view).index == 0
      assert Repo.aggregate(Task, :count) == tasks_before
      assert Repo.aggregate(Board, :count) == boards_before
    end

    test "the demo reaches no database or board context" do
      for file <- ["lib/kanban_web/live/demo_board_live.ex", "lib/kanban_web/demo_board.ex"] do
        refute File.read!(file) =~ ~r/Kanban\.(Repo|Tasks|Boards|Columns|Accounts)\b|Ecto/
      end
    end

    test "cards look read-only and headers carry no add-task link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")
      html = render(view)

      refute html =~ "cursor: grab"
      refute has_element?(view, "[data-demo-board] a[aria-label=\"Add Task\"]")
    end
  end

  describe "visitors and lifecycle" do
    test "two visitors each see their own independent replay" do
      {:ok, first, _html} = live(build_conn(), ~p"/demo")
      {:ok, second, _html} = live(build_conn(), ~p"/demo")

      assert first.pid != second.pid

      tick(first)
      tick(first)

      assert assigns(first).index == 2
      assert assigns(second).index == 0
      assert card_in?(first, "W104", :review)
      assert card_in?(second, "W104", :doing)
    end

    test "a reconnect starts the replay again from the first move", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/demo")
      tick(view)
      assert assigns(view).index == 1

      {:ok, again, _html} = live(conn, ~p"/demo")
      assert assigns(again).index == 0
      assert card_in?(again, "W101", :ready)
    end

    test "the demo stops ticking when the visitor leaves", %{conn: conn} do
      previous = Application.get_env(:kanban, :demo_board_tick_ms)
      Application.put_env(:kanban, :demo_board_tick_ms, 60_000)
      on_exit(fn -> Application.put_env(:kanban, :demo_board_tick_ms, previous) end)

      {:ok, view, _html} = live(conn, ~p"/demo")
      first_timer = assigns(view).tick_timer
      assert is_integer(Process.read_timer(first_timer))

      tick(view)
      timer = assigns(view).tick_timer
      assert Process.read_timer(first_timer) == false
      assert is_integer(Process.read_timer(timer))

      Process.flag(:trap_exit, true)
      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid, :normal)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      assert Process.read_timer(timer) == false
    end
  end

  describe "translations" do
    for locale <- @locales do
      test "card text renders in #{locale}", %{conn: conn} do
        locale = unquote(locale)
        conn = Plug.Test.init_test_session(conn, %{"locale" => locale})
        {:ok, view, _html} = live(conn, ~p"/demo")

        {title, description} =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            {DemoBoard.card_title("W101"), DemoBoardLive.meta_description()}
          end)

        assert has_element?(view, ~s([data-demo-card="W101"]), title)
        assert String.length(description) <= 160

        if locale != "en" do
          refute title == "Add a dark mode toggle to settings"

          refute description ==
                   Gettext.with_locale(KanbanWeb.Gettext, "en", &DemoBoardLive.meta_description/0)
        end
      end
    end
  end
end
