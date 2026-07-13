defmodule KanbanWeb.IssueLive.FormComponentTest do
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    on_exit(fn ->
      Application.delete_env(:kanban, :github)
      Application.delete_env(:kanban, :http_client)
    end)

    :ok
  end

  describe "Issue form on about page" do
    test "renders issue form", %{conn: conn} do
      conn = get(conn, ~p"/about")
      assert html_response(conn, 200) =~ "Submit an Issue"
      assert html_response(conn, 200) =~ "Title"
      assert html_response(conn, 200) =~ "Type"
      assert html_response(conn, 200) =~ "Description"
    end

    test "renders label options", %{conn: conn} do
      conn = get(conn, ~p"/about")
      html = html_response(conn, 200)

      assert html =~ "Defect"
      assert html =~ "Feature Request"
      assert html =~ "Translation"
    end

    test "renders submit button", %{conn: conn} do
      conn = get(conn, ~p"/about")
      html = html_response(conn, 200)

      assert html =~ "Submit Issue"

      # W1399: the submit control now renders via the shared core_components
      # <.button variant="primary"> (theme-aware daisyUI primary), replacing the
      # bespoke inline-styled <button>. It keeps the phx-disable-with submit feedback.
      assert html =~ "btn btn-primary"
      assert html =~ ~s(phx-disable-with)
    end

    test "form has correct input fields", %{conn: conn} do
      conn = get(conn, ~p"/about")
      html = html_response(conn, 200)

      # W1399: <.input> derives field ids from the form id ("issue-form"), so the
      # ids are now "issue-form_<field>" (the names stay "issue[<field>]").
      assert html =~ "issue-form_title"
      assert html =~ "issue-form_body"
      assert html =~ "issue-form_label"
    end
  end

  describe "Issue form LiveView interaction" do
    test "validates required fields on submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_submit(%{issue: %{title: "", body: "", label: "defect"}})

      assert result =~ "can&#39;t be blank" or result =~ "can't be blank"
    end

    test "validates title is required", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_change(%{issue: %{title: "", body: "Some body", label: "defect"}})

      assert result =~ "can&#39;t be blank" or result =~ "can't be blank"
    end

    test "validates body is required", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_change(%{issue: %{title: "Some title", body: "", label: "defect"}})

      assert result =~ "can&#39;t be blank" or result =~ "can't be blank"
    end

    test "rejects a label that is not in the allow-list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_submit(%{
          issue: %{title: "Test Issue", body: "Test body", label: "definitely-not-allowed"}
        })

      assert result =~ "must be one of the listed options"
      # Crucially, the GitHub.create_issue path was NOT reached, so the
      # 'GitHub integration is not configured' error from the test env's
      # missing config does not appear.
      refute result =~ "GitHub integration is not configured"
    end

    test "shows error when GitHub is not configured", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_submit(%{issue: %{title: "Test Issue", body: "Test body", label: "defect"}})

      assert result =~ "GitHub integration is not configured" or
               result =~ "L&#39;intégration GitHub n&#39;est pas configurée"
    end

    @tag :capture_log
    test "shows generic (non-leaking) error when GitHub API returns error (W402)",
         %{conn: conn} do
      # @tag :capture_log silences the expected Logger.error from W402's
      # error path so the test runner output stays clean.
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 500,
           body: %{"message" => "Internal Server Error"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_submit(%{issue: %{title: "Test Issue", body: "Test body", label: "defect"}})

      assert result =~ "Failed to submit issue"
      assert result =~ "Failed to submit the issue. Please try again later."
      # W402: must NOT leak the upstream status code or response details.
      refute result =~ "GitHub API returned status 500"
      refute result =~ "Internal Server Error"
    end

    test "shows success message and link after successful submission", %{conn: conn} do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 201,
           body: %{"html_url" => "https://github.com/owner/repo/issues/42"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_submit(%{issue: %{title: "Test Issue", body: "Test body", label: "defect"}})

      assert result =~ "Issue submitted successfully!" or
               result =~ "Problème soumis avec succès"

      assert result =~ "View your issue on" or result =~ "Voir votre problème sur"
      assert result =~ "https://github.com/owner/repo/issues/42"
      assert result =~ "Submit another issue" or result =~ "Soumettre un autre problème"
    end

    test "reset button returns to form state after successful submission", %{conn: conn} do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 201,
           body: %{"html_url" => "https://github.com/owner/repo/issues/42"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:ok, view, _html} = live(conn, ~p"/issue")

      # Submit the form successfully
      view
      |> element("#issue-form")
      |> render_submit(%{issue: %{title: "Test Issue", body: "Test body", label: "defect"}})

      # Click the reset button
      result =
        view
        |> element("button", "Submit another issue")
        |> render_click()

      # Should show the form again
      assert result =~ "Submit Issue" or result =~ "Soumettre"
      assert result =~ "issue-form_title"
      assert result =~ "issue-form_body"
      refute result =~ "Issue submitted successfully!"
    end

    test "clears validation errors after valid change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      # First trigger an error
      view
      |> element("#issue-form")
      |> render_change(%{issue: %{title: "", body: "", label: "defect"}})

      # Then provide valid input
      result =
        view
        |> element("#issue-form")
        |> render_change(%{issue: %{title: "Valid title", body: "Valid body", label: "defect"}})

      refute result =~ "can&#39;t be blank"
      refute result =~ "can't be blank"
    end

    test "preserves form values during validation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_change(%{
          issue: %{title: "My Title", body: "My Description", label: "feature request"}
        })

      assert result =~ "My Title"
      assert result =~ "My Description"
    end

    test "submits with different label types", %{conn: conn} do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, opts ->
        # Verify the label is passed correctly
        assert opts[:json][:labels] == ["translation"]

        {:ok,
         %Req.Response{
           status: 201,
           body: %{"html_url" => "https://github.com/owner/repo/issues/99"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_submit(%{
          issue: %{title: "Translation fix", body: "Fix translation", label: "translation"}
        })

      assert result =~ "Issue submitted successfully!" or
               result =~ "Problème soumis avec succès"
    end
  end

  describe "W402: input validation + rate limiting" do
    setup do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 201,
           body: %{"html_url" => "https://github.com/owner/repo/issues/42"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      :ok
    end

    test "rejects an oversize title", %{conn: conn} do
      long_title = String.duplicate("a", 201)
      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_submit(%{
          issue: %{title: long_title, body: "Some body", label: "defect"}
        })

      assert result =~ "200" or result =~ "fewer"
      refute result =~ "Issue submitted successfully!"
    end

    test "rejects an oversize body", %{conn: conn} do
      long_body = String.duplicate("a", 4_001)
      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_submit(%{
          issue: %{title: "Short title", body: long_body, label: "defect"}
        })

      assert result =~ "4000" or result =~ "fewer"
      refute result =~ "Issue submitted successfully!"
    end

    test "blocks a rapid follow-up submission within the rate-limit window",
         %{conn: conn} do
      # Enable the shared limiter for this test only, with a tiny :issue budget
      # (1 submission / window). Safe because this module is async: false.
      original = Application.get_env(:kanban, Kanban.RateLimit)

      Application.put_env(:kanban, Kanban.RateLimit,
        enabled: true,
        issue: %{scale_ms: 300_000, ip_limit: 1}
      )

      on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

      {:ok, view, _html} = live(conn, ~p"/issue")

      # First submission — succeeds.
      view
      |> element("#issue-form")
      |> render_submit(%{issue: %{title: "First", body: "First body", label: "defect"}})

      assert render(view) =~ "Issue submitted successfully!"

      # Reset the form (clears submitted state without resetting the rate window).
      view
      |> element("[phx-click='reset']")
      |> render_click()

      # Second submission immediately — should hit the rate limit.
      result =
        view
        |> element("#issue-form")
        |> render_submit(%{issue: %{title: "Second", body: "Second body", label: "defect"}})

      assert result =~ "Please wait" or result =~ "moment"
      refute result =~ "Issue submitted successfully!"
    end
  end
end
