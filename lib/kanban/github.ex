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
  """
  def create_issue(title, body, labels \\ []) do
    config = Application.get_env(:kanban, :github, [])
    token = config[:token]
    repo = config[:repo]

    if is_nil(token) or is_nil(repo) do
      {:error, :not_configured}
    else
      do_create_issue(token, repo, title, body, labels)
    end
  end

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

    case Req.post(url, json: payload, headers: headers) do
      {:ok, %Req.Response{status: 201, body: %{"html_url" => html_url}}} ->
        {:ok, html_url}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "GitHub API returned status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
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
