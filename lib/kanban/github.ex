defmodule Kanban.GitHub do
  @moduledoc """
  Service module for interacting with the GitHub API.
  """

  @github_api_url "https://api.github.com"

  @doc """
  Creates a new issue in the configured GitHub repository.

  ## Parameters

    * `title` - The issue title (required)
    * `body` - The issue body/description (required)
    * `labels` - List of labels to apply to the issue

  ## Returns

    * `{:ok, issue_url}` - The URL of the created issue on success
    * `{:error, reason}` - Error tuple on failure

  Every call emits the `[:kanban, :github, :issue_created]` telemetry event
  with `outcome: :ok` or `outcome: :error` (including when GitHub is not
  configured) and a `reason` from a fixed set: `:none` on success,
  `:not_configured` when the token or repo is missing, `:http_error` when
  GitHub answers with anything but a 201 carrying an issue URL, and
  `:transport_error` when the HTTP request itself fails. The title, body,
  labels, URL and error text are never emitted.
  """
  def create_issue(title, body, labels \\ []) do
    config = Application.get_env(:kanban, :github, [])
    token = config[:token]
    repo = config[:repo]

    classified =
      if is_nil(token) or is_nil(repo) do
        {:error, :not_configured, :not_configured}
      else
        do_create_issue(token, repo, title, body, labels)
      end

    emit_issue_created(classified)
    public_result(classified)
  end

  defp emit_issue_created(classified) do
    Kanban.Telemetry.emit(
      [:kanban, :github, :issue_created],
      %{count: 1},
      issue_metadata(classified)
    )
  end

  # The reason is chosen by these clauses alone, never derived from the
  # response or the error term, so it stays a closed set of four atoms.
  defp issue_metadata({:ok, _issue_url}), do: %{outcome: :ok, reason: :none}

  defp issue_metadata({:error, :not_configured, _error}),
    do: %{outcome: :error, reason: :not_configured}

  defp issue_metadata({:error, :http_error, _error}),
    do: %{outcome: :error, reason: :http_error}

  defp issue_metadata({:error, :transport_error, _error}),
    do: %{outcome: :error, reason: :transport_error}

  defp public_result({:ok, issue_url}), do: {:ok, issue_url}
  defp public_result({:error, _kind, error}), do: {:error, error}

  defp do_create_issue(token, repo, title, body, labels) do
    url = "#{@github_api_url}/repos/#{repo}/issues"

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]

    payload = %{
      title: title,
      body: body,
      labels: labels
    }

    http_client = Application.get_env(:kanban, :http_client, &Req.post/2)

    case http_client.(url, json: payload, headers: headers) do
      {:ok, %Req.Response{status: 201, body: %{"html_url" => html_url}}} ->
        {:ok, html_url}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, :http_error, "GitHub API returned status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, :transport_error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Returns the list of valid labels for issue submission.
  """
  def valid_labels do
    [
      {"defect", "defect"},
      {"feature request", "feature request"},
      {"translation", "translation"}
    ]
  end

  @doc """
  Checks if the GitHub integration is configured.
  """
  def configured? do
    config = Application.get_env(:kanban, :github, [])
    not is_nil(config[:token]) and not is_nil(config[:repo])
  end
end
