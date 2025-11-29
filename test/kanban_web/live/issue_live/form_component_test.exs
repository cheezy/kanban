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
    end

    test "form has correct input fields", %{conn: conn} do
      conn = get(conn, ~p"/about")
      html = html_response(conn, 200)

      assert html =~ "issue_title"
      assert html =~ "issue_body"
      assert html =~ "issue_label"
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

    test "shows error when GitHub is not configured", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      result =
        view
        |> element("#issue-form")
        |> render_submit(%{issue: %{title: "Test Issue", body: "Test body", label: "defect"}})

      assert result =~ "GitHub integration is not configured" or
               result =~ "L&#39;intégration GitHub n&#39;est pas configurée"
    end

    test "shows generic error when GitHub API returns error", %{conn: conn} do
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
      assert result =~ "GitHub API returned status 500"
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
      assert result =~ "issue_title"
      assert result =~ "issue_body"
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
end
