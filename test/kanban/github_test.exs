defmodule Kanban.GitHubTest do
  use ExUnit.Case, async: false

  import Kanban.TelemetryHelpers

  alias Kanban.GitHub

  describe "valid_labels/0" do
    test "returns the list of valid label options" do
      labels = GitHub.valid_labels()

      assert length(labels) == 3
      assert {"defect", "defect"} in labels
      assert {"feature request", "feature request"} in labels
      assert {"translation", "translation"} in labels
    end
  end

  describe "configured?/0" do
    test "returns false when github config is not set" do
      # Ensure no config is set
      Application.delete_env(:kanban, :github)

      refute GitHub.configured?()
    end

    test "returns false when only token is set" do
      Application.put_env(:kanban, :github, token: "test-token")

      refute GitHub.configured?()

      Application.delete_env(:kanban, :github)
    end

    test "returns false when only repo is set" do
      Application.put_env(:kanban, :github, repo: "owner/repo")

      refute GitHub.configured?()

      Application.delete_env(:kanban, :github)
    end

    test "returns true when both token and repo are set" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      assert GitHub.configured?()

      Application.delete_env(:kanban, :github)
    end
  end

  describe "create_issue/3" do
    setup do
      on_exit(fn ->
        Application.delete_env(:kanban, :github)
        Application.delete_env(:kanban, :http_client)
      end)

      :ok
    end

    @issue_created [:kanban, :github, :issue_created]

    test "a created issue emits github.issue_created with outcome ok" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      Application.put_env(:kanban, :http_client, fn _url, _opts ->
        {:ok, %Req.Response{status: 201, body: %{"html_url" => "https://github.com/o/r/1"}}}
      end)

      attach_telemetry(@issue_created)

      assert {:ok, _url} = GitHub.create_issue("Secret title", "Secret body", ["defect"])

      assert_receive {:telemetry_event, @issue_created, %{count: 1}, metadata}
      # Only the outcome and reason: never the title, body, labels or issue URL.
      assert metadata == %{outcome: :ok, reason: :none}
    end

    test "a failed request emits github.issue_created with outcome error" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      Application.put_env(:kanban, :http_client, fn _url, _opts ->
        {:ok, %Req.Response{status: 500, body: %{"message" => "boom"}}}
      end)

      attach_telemetry(@issue_created)

      assert {:error, message} = GitHub.create_issue("title", "body", [])
      assert message =~ "GitHub API returned status 500"

      assert_receive {:telemetry_event, @issue_created, %{count: 1}, metadata}
      assert metadata == %{outcome: :error, reason: :http_error}
    end

    test "classifies a 201 without html_url and non-201 statuses as http_error" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")
      attach_telemetry(@issue_created)

      for {status, body} <- [
            {201, %{}},
            {401, %{"message" => "Bad credentials"}},
            {403, %{"message" => "API rate limit exceeded"}},
            {404, %{"message" => "Not Found"}},
            {422, %{"message" => "Validation Failed"}},
            {500, %{"message" => "boom"}}
          ] do
        Application.put_env(:kanban, :http_client, fn _url, _opts ->
          {:ok, %Req.Response{status: status, body: body}}
        end)

        assert {:error, message} = GitHub.create_issue("title", "body", [])
        assert message =~ "GitHub API returned status #{status}"

        assert_receive {:telemetry_event, @issue_created, %{count: 1}, metadata}
        assert metadata == %{outcome: :error, reason: :http_error}
      end
    end

    test "a transport failure emits github.issue_created with reason transport_error" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")
      attach_telemetry(@issue_created)

      for error <- [%Req.TransportError{reason: :econnrefused}, "boom"] do
        Application.put_env(:kanban, :http_client, fn _url, _opts -> {:error, error} end)

        assert {:error, message} = GitHub.create_issue("title", "body", [])
        assert message =~ "HTTP request failed"

        assert_receive {:telemetry_event, @issue_created, %{count: 1}, metadata}
        assert metadata == %{outcome: :error, reason: :transport_error}
      end
    end

    test "issue_created metadata never carries error text or request details" do
      Application.put_env(:kanban, :github, token: "tok-123", repo: "owner/repo")
      attach_telemetry(@issue_created)

      clients = [
        fn _url, _opts ->
          {:ok, %Req.Response{status: 401, body: %{"message" => "Bad credentials"}}}
        end,
        fn _url, _opts -> {:error, %Req.TransportError{reason: :econnrefused}} end,
        fn _url, _opts ->
          {:ok, %Req.Response{status: 201, body: %{"html_url" => "https://github.com/o/r/9"}}}
        end
      ]

      for client <- clients do
        Application.put_env(:kanban, :http_client, client)
        GitHub.create_issue("Secret title", "Private body", ["defect"])

        assert_receive {:telemetry_event, @issue_created, %{count: 1}, metadata}
        assert metadata |> Map.keys() |> Enum.sort() == [:outcome, :reason]
        assert metadata |> Map.values() |> Enum.all?(&is_atom/1)

        rendered = inspect(metadata)

        for leaked <- [
              "Bad credentials",
              "econnrefused",
              "tok-123",
              "owner/repo",
              "Secret title",
              "Private body",
              "defect",
              "github.com"
            ] do
          refute rendered =~ leaked
        end
      end
    end

    test "an unconfigured integration emits github.issue_created with outcome error" do
      Application.delete_env(:kanban, :github)
      attach_telemetry(@issue_created)

      assert {:error, :not_configured} = GitHub.create_issue("title", "body", [])

      assert_receive {:telemetry_event, @issue_created, %{count: 1}, metadata}
      assert metadata == %{outcome: :error, reason: :not_configured}
    end

    test "a half-configured integration emits reason not_configured" do
      attach_telemetry(@issue_created)

      for config <- [[token: "token"], [repo: "owner/repo"], [token: nil, repo: "owner/repo"]] do
        Application.put_env(:kanban, :github, config)

        assert {:error, :not_configured} = GitHub.create_issue("title", "body", [])

        assert_receive {:telemetry_event, @issue_created, %{count: 1}, metadata}
        assert metadata == %{outcome: :error, reason: :not_configured}
      end
    end

    test "returns error when not configured" do
      Application.delete_env(:kanban, :github)

      assert {:error, :not_configured} = GitHub.create_issue("title", "body", ["defect"])
    end

    test "returns error when token is nil" do
      Application.put_env(:kanban, :github, token: nil, repo: "owner/repo")

      assert {:error, :not_configured} = GitHub.create_issue("title", "body", ["defect"])
    end

    test "returns error when repo is nil" do
      Application.put_env(:kanban, :github, token: "token", repo: nil)

      assert {:error, :not_configured} = GitHub.create_issue("title", "body", ["defect"])
    end

    test "returns issue URL on successful creation (201)" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn url, opts ->
        assert url == "https://api.github.com/repos/owner/repo/issues"
        assert opts[:json] == %{title: "Test Issue", body: "Test body", labels: ["defect"]}

        headers = opts[:headers]
        assert {"Authorization", "Bearer test-token"} in headers
        assert {"Accept", "application/vnd.github+json"} in headers
        assert {"X-GitHub-Api-Version", "2022-11-28"} in headers

        {:ok,
         %Req.Response{
           status: 201,
           body: %{"html_url" => "https://github.com/owner/repo/issues/123"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      assert {:ok, "https://github.com/owner/repo/issues/123"} =
               GitHub.create_issue("Test Issue", "Test body", ["defect"])
    end

    test "returns issue URL with multiple labels" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, opts ->
        assert opts[:json][:labels] == ["defect", "feature request"]

        {:ok,
         %Req.Response{
           status: 201,
           body: %{"html_url" => "https://github.com/owner/repo/issues/456"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      assert {:ok, "https://github.com/owner/repo/issues/456"} =
               GitHub.create_issue("Title", "Body", ["defect", "feature request"])
    end

    test "returns issue URL with empty labels list" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, opts ->
        assert opts[:json][:labels] == []

        {:ok,
         %Req.Response{
           status: 201,
           body: %{"html_url" => "https://github.com/owner/repo/issues/789"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      assert {:ok, "https://github.com/owner/repo/issues/789"} =
               GitHub.create_issue("Title", "Body")
    end

    test "returns error on non-201 status (401 Unauthorized)" do
      Application.put_env(:kanban, :github, token: "invalid-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 401,
           body: %{"message" => "Bad credentials"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:error, message} = GitHub.create_issue("Title", "Body", ["defect"])
      assert message =~ "GitHub API returned status 401"
      assert message =~ "Bad credentials"
    end

    test "returns error on non-201 status (403 Forbidden)" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 403,
           body: %{"message" => "API rate limit exceeded"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:error, message} = GitHub.create_issue("Title", "Body", ["defect"])
      assert message =~ "GitHub API returned status 403"
      assert message =~ "API rate limit exceeded"
    end

    test "returns error on non-201 status (404 Not Found)" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "nonexistent/repo")

      mock_client = fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 404,
           body: %{"message" => "Not Found"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:error, message} = GitHub.create_issue("Title", "Body", ["defect"])
      assert message =~ "GitHub API returned status 404"
      assert message =~ "Not Found"
    end

    test "returns error on non-201 status (422 Validation Failed)" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 422,
           body: %{
             "message" => "Validation Failed",
             "errors" => [%{"resource" => "Issue", "code" => "missing_field", "field" => "title"}]
           }
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:error, message} = GitHub.create_issue("", "Body", ["defect"])
      assert message =~ "GitHub API returned status 422"
      assert message =~ "Validation Failed"
    end

    test "returns error on HTTP request failure (network error)" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:error, message} = GitHub.create_issue("Title", "Body", ["defect"])
      assert message =~ "HTTP request failed"
      assert message =~ "econnrefused"
    end

    test "returns error on HTTP request failure (timeout)" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:error, message} = GitHub.create_issue("Title", "Body", ["defect"])
      assert message =~ "HTTP request failed"
      assert message =~ "timeout"
    end

    test "returns error on HTTP request failure (DNS resolution)" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "owner/repo")

      mock_client = fn _url, _opts ->
        {:error, %Req.TransportError{reason: :nxdomain}}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      {:error, message} = GitHub.create_issue("Title", "Body", ["defect"])
      assert message =~ "HTTP request failed"
      assert message =~ "nxdomain"
    end

    test "constructs correct URL with different repo formats" do
      Application.put_env(:kanban, :github, token: "test-token", repo: "my-org/my-project")

      mock_client = fn url, _opts ->
        assert url == "https://api.github.com/repos/my-org/my-project/issues"

        {:ok,
         %Req.Response{
           status: 201,
           body: %{"html_url" => "https://github.com/my-org/my-project/issues/1"}
         }}
      end

      Application.put_env(:kanban, :http_client, mock_client)

      assert {:ok, _} = GitHub.create_issue("Title", "Body")
    end
  end
end
