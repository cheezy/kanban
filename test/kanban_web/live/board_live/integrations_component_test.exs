defmodule KanbanWeb.BoardLive.IntegrationsComponentTest do
  use KanbanWeb.ConnCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.WebhooksFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Webhooks
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Transport
  alias KanbanWeb.BoardLive.IntegrationsComponent

  @generic_url "https://hooks.example.com/stride/secret-path?token=abc"
  @slack_url "https://hooks.slack.com/services/T000/B000/XXXX"
  @not_found "Endpoint not found"
  @owner_only "Only the board owner can manage integrations"

  defp open(conn, user, board) do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/boards/#{board}/integrations")
    view
  end

  defp target(board), do: "#board-integrations-#{board.id}"

  defp form(view), do: element(view, "form[id^=webhook-endpoint-form]")

  defp create(view, attrs) do
    params =
      Map.merge(
        %{"kind" => "generic", "url" => @generic_url, "event_types" => ["task.created"]},
        attrs
      )

    view |> form() |> render_submit(%{"endpoint" => params})
  end

  defp secret_from(view) do
    view
    |> element("#webhook-secret-value")
    |> render()
    |> then(&Regex.run(~r/>([^<]+)</, &1))
    |> List.last()
    |> String.trim()
  end

  defp endpoints(board), do: Endpoint |> Repo.all() |> Enum.filter(&(&1.board_id == board.id))

  defp edit_form(view, endpoint), do: element(view, "#webhook-edit-form-#{endpoint.id}")

  defp open_edit(view, endpoint) do
    view |> element("#webhook-edit-#{endpoint.id}") |> render_click()
    assert has_element?(view, "#webhook-edit-form-#{endpoint.id}")
    view
  end

  defp save_edit(view, endpoint, params) do
    view |> edit_form(endpoint) |> render_submit(%{"endpoint_edit" => params})
  end

  setup do
    Repo.delete_all(Oban.Job)
    owner = user_fixture()
    %{owner: owner, board: board_fixture(owner)}
  end

  describe "as the board owner" do
    test "shows the Integrations tab and an empty state", %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)

      assert has_element?(view, ~s(a[href="/boards/#{ctx.board.id}/integrations"]))
      assert has_element?(view, "[data-webhooks-empty]")
      assert has_element?(view, ~s([role="dialog"][aria-label="Integrations"]))
      assert page_title(view) =~ "Integrations"
    end

    test "an AI-optimized board gets integrations too", %{conn: conn} = ctx do
      board = ai_optimized_board_fixture(ctx.owner)
      view = open(conn, ctx.owner, board)

      assert has_element?(view, target(board))
    end

    test "creates a generic endpoint, shows only its host and reveals the secret once",
         %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)

      html = create(view, %{"event_types" => ["task.created", "task.moved"]})

      assert [endpoint] = endpoints(ctx.board)
      assert endpoint.event_types == ["task.created", "task.moved"]

      assert has_element?(
               view,
               "#webhook-endpoint-#{endpoint.id} [data-endpoint-host]",
               "hooks.example.com"
             )

      refute html =~ "secret-path"
      refute html =~ "token=abc"

      secret = secret_from(view)
      assert {:ok, ^secret} = Webhooks.signing_secret(endpoint)
      refute html =~ ~s(data-token-value)
      assert render(view) =~ "Endpoint created"
    end

    test "the secret is gone after dismiss, after closing the modal and after a reload",
         %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)
      create(view, %{})
      secret = secret_from(view)

      view |> element("#webhook-secret-dismiss") |> render_click()
      refute has_element?(view, "#webhook-secret")
      refute render(view) =~ secret

      create(view, %{"url" => "https://hooks.example.com/two"})
      second = secret_from(view)
      render_patch(view, ~p"/boards/#{ctx.board}")
      render_patch(view, ~p"/boards/#{ctx.board}/integrations")
      refute has_element?(view, "#webhook-secret")
      refute render(view) =~ second

      reloaded = open(conn, ctx.owner, ctx.board)
      refute has_element?(reloaded, "#webhook-secret")
      refute render(reloaded) =~ second
    end

    test "creates a Slack endpoint without revealing a secret or offering rotate",
         %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)
      html = create(view, %{"kind" => "slack", "url" => @slack_url})

      assert [%Endpoint{kind: :slack} = endpoint] = endpoints(ctx.board)
      refute has_element?(view, "#webhook-secret")
      refute has_element?(view, "#webhook-rotate-#{endpoint.id}")
      assert has_element?(view, ~s(#webhook-endpoint-#{endpoint.id} [data-endpoint-kind="slack"]))
      refute html =~ "T000/B000"
    end

    test "invalid or blocked URLs show an inline error and save nothing", %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)

      for {attrs, message} <- [
            {%{"url" => "not a url"}, "is not a valid URL"},
            {%{"url" => "https://10.0.0.1/h"}, "points to a private or reserved network address"},
            {%{"url" => "https://internal.example.com/h"},
             "points to a private or reserved network address"},
            {%{"url" => "https://nowhere.example.com/"},
             "has a host name that could not be found"},
            {%{"event_types" => [""]}, "should have at least 1 item(s)"},
            {%{"kind" => "slack"}, "must be a Slack incoming webhook URL"}
          ] do
        html = create(view, attrs)
        assert html =~ message, "expected #{inspect(message)} for #{inspect(attrs)}"
      end

      assert endpoints(ctx.board) == []
      refute has_element?(view, "#webhook-secret")
    end

    test "the page title and inline errors are translated", %{conn: conn} = ctx do
      conn = conn |> log_in_user(ctx.owner) |> Plug.Conn.put_session(:locale, "de")
      {:ok, view, _html} = live(conn, ~p"/boards/#{ctx.board}/integrations")

      assert page_title(view) =~ "Integrationen"
      assert create(view, %{"url" => "not a url"}) =~ "ist keine gültige URL"
    end

    test "validate shows errors while typing and saves nothing", %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)

      html =
        view
        |> form()
        |> render_change(%{
          "endpoint" => %{"kind" => "generic", "url" => "nope", "event_types" => [""]}
        })

      assert html =~ "must start with https://"
      assert html =~ "should have at least 1 item(s)"
      assert endpoints(ctx.board) == []
    end

    test "toggle disables and re-enables an endpoint", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      view = open(conn, ctx.owner, ctx.board)

      view |> element("#webhook-toggle-#{endpoint.id}") |> render_click()
      refute Repo.get!(Endpoint, endpoint.id).enabled

      assert has_element?(
               view,
               ~s(#webhook-toggle-#{endpoint.id}[data-enabled="false"]),
               "Enable"
             )

      assert has_element?(view, "#webhook-endpoint-#{endpoint.id} [data-endpoint-disabled]")

      view |> element("#webhook-toggle-#{endpoint.id}") |> render_click()
      assert Repo.get!(Endpoint, endpoint.id).enabled

      assert has_element?(
               view,
               ~s(#webhook-toggle-#{endpoint.id}[data-enabled="true"]),
               "Disable"
             )
    end

    test "rotate shows a new secret that replaces the old one", %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)
      create(view, %{})
      old = secret_from(view)
      [endpoint] = endpoints(ctx.board)

      view |> element("#webhook-rotate-#{endpoint.id}") |> render_click()

      new = secret_from(view)
      refute new == old

      assert {:ok, ^new} =
               endpoint.id |> then(&Repo.get!(Endpoint, &1)) |> Webhooks.signing_secret()

      assert render(view) =~ "Secret rotated"
    end

    test "delete removes the endpoint and its row", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      view = open(conn, ctx.owner, ctx.board)

      view |> element("#webhook-delete-#{endpoint.id}") |> render_click()

      refute Repo.get(Endpoint, endpoint.id)
      refute has_element?(view, "#webhook-endpoint-#{endpoint.id}")
      assert has_element?(view, "[data-webhooks-empty]")
    end

    test "send test queues a ping and the log shows its status after the job runs",
         %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, url: "https://hooks.example.com/ping")
      Req.Test.stub(Transport, &Plug.Conn.send_resp(&1, 204, ""))
      view = open(conn, ctx.owner, ctx.board)

      view |> element("#webhook-test-#{endpoint.id}") |> render_click()

      assert_enqueued(worker: DeliveryWorker, args: %{endpoint_id: endpoint.id, event: "ping"})
      assert has_element?(view, "#webhook-log-#{endpoint.id} [data-deliveries-empty]")

      [job] = all_enqueued(worker: DeliveryWorker)
      assert :ok = perform_job(DeliveryWorker, job.args)

      view |> element("#webhook-log-refresh-#{endpoint.id}") |> render_click()

      assert has_element?(
               view,
               ~s(#webhook-log-#{endpoint.id} [data-delivery-status="succeeded"])
             )

      assert has_element?(view, "#webhook-log-#{endpoint.id} td", "ping")
      assert has_element?(view, "#webhook-log-#{endpoint.id} td", "204")
    end

    test "send test on a disabled endpoint shows an error and queues nothing",
         %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, enabled: false)
      view = open(conn, ctx.owner, ctx.board)

      view |> element("#webhook-test-#{endpoint.id}") |> render_click()

      assert render(view) =~ "Enable the endpoint before sending a test event"
      refute_enqueued(worker: DeliveryWorker)
    end

    test "the log shows the 20 most recent deliveries and hides again", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      ids = for n <- 1..25, do: delivery_fixture(endpoint, %{attempt: n, status: :failed}).id
      view = open(conn, ctx.owner, ctx.board)

      view |> element("#webhook-log-toggle-#{endpoint.id}") |> render_click()

      shown = for id <- ids, has_element?(view, "#webhook-delivery-#{id}"), do: id
      assert shown == Enum.take(ids, -20)
      assert has_element?(view, ~s([data-delivery-status="failed"]))

      view |> element("#webhook-log-toggle-#{endpoint.id}") |> render_click()
      refute has_element?(view, "#webhook-log-#{endpoint.id}")
    end

    test "very long delivery errors are cut in the log", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      long = "HTTP 500: " <> String.duplicate("x", 5000)
      delivery = delivery_fixture(endpoint, %{status: :failed, response_status: 500, error: long})
      view = open(conn, ctx.owner, ctx.board)

      view |> element("#webhook-log-toggle-#{endpoint.id}") |> render_click()

      cell = view |> element("#webhook-delivery-#{delivery.id} td[title]") |> render()
      assert cell =~ "…"
      [_, text] = Regex.run(~r/>\s*([^<]*?)\s*</, cell)
      assert String.length(text) <= 161

      # The tooltip is cut too, so a log of 64 KB errors stays small.
      [_, title] = Regex.run(~r/title="([^"]*)"/, cell)
      assert String.starts_with?(title, "HTTP 500: xxx")
      assert String.length(title) == 2_001
      assert String.ends_with?(title, "…")
    end

    test "an endpoint id from another board, or a malformed id, is refused for every action",
         %{conn: conn} = ctx do
      foreign_board = board_fixture(ctx.owner)
      foreign = webhook_endpoint_fixture(foreign_board)
      view = open(conn, ctx.owner, ctx.board)

      for id <- ["#{foreign.id}", "not-an-id"],
          event <- ~w(toggle rotate delete send_test show_log) do
        view |> with_target(target(ctx.board)) |> render_click(event, %{"id" => id})
        assert render(view) =~ @not_found, "#{event} with #{id} was not refused"
      end

      unchanged = Repo.get!(Endpoint, foreign.id)
      assert unchanged.enabled
      assert unchanged.lock_version == foreign.lock_version
      assert unchanged.encrypted_secret == foreign.encrypted_secret
      refute has_element?(view, "#webhook-secret")
      refute_enqueued(worker: DeliveryWorker)
    end
  end

  describe "editing an endpoint" do
    test "editing an endpoint's events saves them, closes the form, flashes \"Endpoint updated\" and the row shows the new events",
         %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, event_types: ["task.created"])
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      save_edit(view, endpoint, %{"event_types" => ["", "task.moved", "task.deleted"]})

      saved = Repo.get!(Endpoint, endpoint.id)
      assert saved.event_types == ["task.moved", "task.deleted"]
      assert saved.url == endpoint.url
      assert render(view) =~ "Endpoint updated"
      refute has_element?(view, "#webhook-edit-form-#{endpoint.id}")
      assert has_element?(view, "#webhook-endpoint-#{endpoint.id} code", "task.moved")
      assert has_element?(view, "#webhook-endpoint-#{endpoint.id} code", "task.deleted")
      refute has_element?(view, "#webhook-endpoint-#{endpoint.id} code", "task.created")
    end

    test "the edit form ticks the current events, shows the kind read-only and leaves the URL empty",
         %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, event_types: ["task.moved"])
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      form_html = view |> edit_form(endpoint) |> render()
      assert form_html =~ ~r/value="task.moved"\s+checked/
      refute form_html =~ ~r/value="task.created"\s+checked/
      refute form_html =~ "<select"
      assert has_element?(view, ~s(#webhook-edit-form-#{endpoint.id} [data-edit-kind="generic"]))
      assert has_element?(view, ~s(#webhook-edit-url-#{endpoint.id}[value=""]))
      assert has_element?(view, "#webhook-edit-#{endpoint.id}[aria-expanded=true]")
    end

    test "unticking every event shows the inline error and saves nothing", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, event_types: ["task.created"])
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      html = save_edit(view, endpoint, %{"event_types" => [""]})

      assert html =~ "should have at least 1 item(s)"
      assert Repo.get!(Endpoint, endpoint.id).event_types == ["task.created"]
      assert has_element?(view, "#webhook-edit-form-#{endpoint.id}")
      refute html =~ "Endpoint updated"
    end

    test "a blocked or malformed URL shows an inline error and saves nothing",
         %{conn: conn} = ctx do
      generic = webhook_endpoint_fixture(ctx.board)
      slack = webhook_endpoint_fixture(ctx.board, kind: :slack, url: @slack_url)
      view = open(conn, ctx.owner, ctx.board)

      for {endpoint, url, message} <- [
            {generic, "not a url", "is not a valid URL"},
            {generic, "ftp://hooks.example.com/h", "must start with https://"},
            {generic, "https://10.0.0.1/h", "points to a private or reserved network address"},
            {generic, "https://internal.example.com/h",
             "points to a private or reserved network address"},
            {generic, "https://nowhere.example.com/", "has a host name that could not be found"},
            {slack, "https://hooks.example.com/x", "must be a Slack incoming webhook URL"}
          ] do
        open_edit(view, endpoint)
        html = save_edit(view, endpoint, %{"url" => url, "event_types" => ["task.created"]})
        assert html =~ message, "expected #{inspect(message)} for #{inspect(url)}"
        assert has_element?(view, "#webhook-edit-form-#{endpoint.id}")
      end

      assert Repo.get!(Endpoint, generic.id).url == generic.url
      assert Repo.get!(Endpoint, slack.id).url == @slack_url
    end

    test "validate_edit shows a URL error while typing and saves nothing", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      html =
        view
        |> edit_form(endpoint)
        |> render_change(%{"endpoint_edit" => %{"url" => "nope", "event_types" => [""]}})

      assert html =~ "must start with https://"
      assert html =~ "should have at least 1 item(s)"
      assert has_element?(view, ~s(#webhook-edit-url-#{endpoint.id}[value="nope"]))

      assert Repo.get!(Endpoint, endpoint.id) |> Map.take([:url, :event_types]) ==
               Map.take(endpoint, [:url, :event_types])
    end

    test "saving with a blank URL keeps the stored URL; saving a new URL stores it and the row shows the new host",
         %{conn: conn} = ctx do
      endpoint =
        webhook_endpoint_fixture(ctx.board, url: "https://old.example.com/stride/1")

      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      save_edit(view, endpoint, %{"url" => "   ", "event_types" => ["task.moved"]})
      assert Repo.get!(Endpoint, endpoint.id).url == "https://old.example.com/stride/1"
      assert Repo.get!(Endpoint, endpoint.id).event_types == ["task.moved"]

      open_edit(view, endpoint)

      save_edit(view, endpoint, %{
        "url" => " https://hooks.example.com/new ",
        "event_types" => ["task.moved"]
      })

      html = render(view)
      assert Repo.get!(Endpoint, endpoint.id).url == "https://hooks.example.com/new"
      assert html =~ "Endpoint updated"

      assert has_element?(
               view,
               "#webhook-endpoint-#{endpoint.id} [data-endpoint-host]",
               "hooks.example.com"
             )

      refute html =~ "old.example.com"
    end

    test "edit and save_edit with another board's endpoint id, a deleted endpoint's id or a malformed id flash \"Endpoint not found\" and change nothing",
         %{conn: conn} = ctx do
      foreign = ctx.owner |> board_fixture() |> webhook_endpoint_fixture()
      deleted = webhook_endpoint_fixture(ctx.board)
      Repo.delete!(deleted)
      view = open(conn, ctx.owner, ctx.board)

      params = %{"url" => "https://hooks.example.com/forged", "event_types" => ["task.moved"]}

      for id <- ["#{foreign.id}", "#{deleted.id}", "not-an-id"],
          {event, value} <- [
            {"edit", %{"id" => id}},
            {"validate_edit", %{"id" => id, "endpoint_edit" => params}},
            {"save_edit", %{"id" => id, "endpoint_edit" => params}},
            {"save_edit", %{"id" => id}}
          ] do
        view |> with_target(target(ctx.board)) |> render_submit(event, value)
        assert render(view) =~ @not_found, "#{event} with #{id} was not refused"
      end

      unchanged = Repo.get!(Endpoint, foreign.id)
      assert unchanged.url == foreign.url
      assert unchanged.event_types == foreign.event_types
      assert endpoints(ctx.board) == []
    end

    test "an endpoint deleted while its edit form is open is refused on save and the form closes",
         %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      {:ok, _} = ctx.owner |> Scope.for_user() |> Webhooks.delete_endpoint(endpoint)

      save_edit(view, endpoint, %{"event_types" => ["task.moved"]})

      assert render(view) =~ @not_found
      refute has_element?(view, "#webhook-edit-form-#{endpoint.id}")
      assert endpoints(ctx.board) == []
    end

    test "a generic endpoint's signing secret (Webhooks.signing_secret/1) and its delivery rows are unchanged after an edit that changes the URL",
         %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      {:ok, secret} = Webhooks.signing_secret(endpoint)
      delivery = delivery_fixture(endpoint, %{status: :succeeded, response_status: 200})
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      assert has_element?(view, "#webhook-edit-form-#{endpoint.id} [data-rotate-note]")

      html =
        save_edit(view, endpoint, %{
          "url" => "https://hooks.example.com/moved",
          "event_types" => ["task.created"]
        })

      saved = Repo.get!(Endpoint, endpoint.id)
      assert saved.url == "https://hooks.example.com/moved"
      assert {:ok, ^secret} = Webhooks.signing_secret(saved)
      assert saved.encrypted_secret == endpoint.encrypted_secret

      assert [%{id: id}] = ctx.owner |> Scope.for_user() |> Webhooks.list_deliveries(saved)

      assert id == delivery.id
      refute has_element?(view, "#webhook-secret")
      refute html =~ secret
    end

    test "Cancel closes the edit form and nothing is saved", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, event_types: ["task.created"])
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      view
      |> edit_form(endpoint)
      |> render_change(%{"endpoint_edit" => %{"event_types" => ["", "task.moved"]}})

      view |> element("#webhook-edit-cancel-#{endpoint.id}") |> render_click()

      refute has_element?(view, "#webhook-edit-form-#{endpoint.id}")
      assert has_element?(view, "#webhook-edit-#{endpoint.id}[aria-expanded=false]")
      assert Repo.get!(Endpoint, endpoint.id).event_types == ["task.created"]
    end

    test "editing a disabled endpoint keeps it disabled", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, enabled: false)
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      save_edit(view, endpoint, %{"event_types" => ["task.moved"]})

      refute Repo.get!(Endpoint, endpoint.id).enabled
      assert has_element?(view, "#webhook-endpoint-#{endpoint.id} [data-endpoint-disabled]")
    end

    test "opening a second endpoint's edit form closes the first", %{conn: conn} = ctx do
      first = webhook_endpoint_fixture(ctx.board)
      second = webhook_endpoint_fixture(ctx.board)
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(first)

      open_edit(view, second)

      refute has_element?(view, "#webhook-edit-form-#{first.id}")
      assert has_element?(view, "#webhook-edit-form-#{second.id}")
    end

    test "the edit form and its flash are translated", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      conn = conn |> log_in_user(ctx.owner) |> Plug.Conn.put_session(:locale, "de")
      {:ok, view, _html} = live(conn, ~p"/boards/#{ctx.board}/integrations")

      open_edit(view, endpoint)
      html = view |> edit_form(endpoint) |> render()
      assert html =~ "Endpunkt bearbeiten"
      assert html =~ "Leer lassen, um die aktuelle URL (hooks.example.com) zu behalten."

      save_edit(view, endpoint, %{"event_types" => ["task.moved"]})
      assert render(view) =~ "Endpunkt aktualisiert"
    end

    test "deleting the endpoint being edited closes its form", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      view |> element("#webhook-delete-#{endpoint.id}") |> render_click()

      refute has_element?(view, "#webhook-edit-form-#{endpoint.id}")
    end

    test "crafted edit params with kind and enabled leave both unchanged", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board)
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      view
      |> with_target(target(ctx.board))
      |> render_submit("save_edit", %{
        "id" => "#{endpoint.id}",
        "endpoint_edit" => %{
          "kind" => "slack",
          "enabled" => "false",
          "board_id" => "#{endpoint.board_id + 1}",
          "event_types" => ["task.moved"]
        }
      })

      saved = Repo.get!(Endpoint, endpoint.id)
      assert saved.kind == :generic
      assert saved.enabled
      assert saved.board_id == endpoint.board_id
      assert saved.event_types == ["task.moved"]
    end

    test "the rendered HTML never contains the endpoint's full stored URL", %{conn: conn} = ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, kind: :slack, url: @slack_url)
      view = conn |> open(ctx.owner, ctx.board) |> open_edit(endpoint)

      opened = render(view)

      changed =
        view
        |> edit_form(endpoint)
        |> render_change(%{"endpoint_edit" => %{"url" => "", "event_types" => ["task.moved"]}})

      failed = save_edit(view, endpoint, %{"event_types" => [""]})

      for html <- [opened, changed, failed] do
        refute html =~ "T000/B000"
        refute html =~ "services/T000"
        assert html =~ "hooks.slack.com"
      end

      refute has_element?(view, "#webhook-edit-form-#{endpoint.id} [data-rotate-note]")
    end
  end

  describe "as a non-owner" do
    test "modify and read-only members opening the URL are redirected with a flash",
         %{conn: conn} = ctx do
      for access <- [:modify, :read_only] do
        member = user_fixture()
        {:ok, _} = Boards.add_user_to_board(ctx.board, member, access, ctx.owner)

        assert {:error, {kind, %{to: to, flash: flash}}} =
                 live(log_in_user(conn, member), ~p"/boards/#{ctx.board}/integrations")

        assert kind in [:live_redirect, :live_patch]
        assert to == "/boards/#{ctx.board.id}"
        assert flash["error"] == @owner_only
      end
    end

    test "members do not see the Integrations tab", %{conn: conn} = ctx do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, member, :modify, ctx.owner)

      {:ok, view, _html} = live(log_in_user(conn, member), ~p"/boards/#{ctx.board}")

      refute has_element?(view, ~s(a[href="/boards/#{ctx.board.id}/integrations"]))
    end

    test "a scope that lost ownership gets nothing from the context", ctx do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(ctx.board, member, :modify, ctx.owner)

      scope = Scope.for_user(member)
      assert Webhooks.create_endpoint(scope, ctx.board, %{}) == {:error, :unauthorized}

      endpoint = webhook_endpoint_fixture(ctx.board)

      assert Webhooks.update_endpoint(scope, endpoint, %{"event_types" => ["task.moved"]}) ==
               {:error, :unauthorized}
    end
  end

  test "apply_parent_message/2 puts the flash" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

    socket = IntegrationsComponent.apply_parent_message(socket, {:flash, :error, "nope"})

    assert socket.assigns.flash == %{"error" => "nope"}
  end
end
