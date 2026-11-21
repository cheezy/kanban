defmodule KanbanWeb.RobotsTxt do
  @moduledoc """
  Builds the body of `/robots.txt`, which `KanbanWeb.SeoController` serves
  (W2891), and the explicit AI crawler policy in it (W2900).

  The controller decides which body a request gets. The canonical host of an
  indexable deployment gets `canonical/1`; every other host gets
  `disallow_all/0`, which disallows everything for every crawler, AI crawlers
  included, so no copy of the site is crawled as a duplicate of the real one.

  The AI crawlers are the one list in `@ai_crawlers`, and whether they may
  crawl is the one `@ai_crawler_policy` attribute. Each crawler gets its own
  `User-agent` group, because a crawler that matches a named group ignores
  the `*` group, and the policy is stated in a comment above the groups.

  With the policy `:allow` (the default), each AI crawler gets the same rules
  as every other crawler, `Disallow: /api/`, plus an `Allow` for the two public
  API documents `/llms.txt` links: the agent onboarding endpoint and the
  OpenAPI document. With `:disallow`, each one gets `Disallow: /`.
  """

  alias KanbanWeb.Endpoint

  @ai_crawlers ~w(GPTBot ClaudeBot PerplexityBot Google-Extended)

  @ai_crawler_policy :allow

  # The public, unauthenticated API documents /llms.txt links.
  @public_api_paths ~w(/api/agent/onboarding /api/openapi.json)

  @type policy :: :allow | :disallow

  @doc """
  The user agents of the AI crawlers `robots.txt` names, in the order it
  names them.
  """
  @spec ai_crawlers() :: [String.t()]
  def ai_crawlers, do: @ai_crawlers

  @doc """
  Whether the AI crawlers may crawl the canonical host: `:allow` or
  `:disallow`.
  """
  @spec ai_crawler_policy() :: policy()
  def ai_crawler_policy, do: @ai_crawler_policy

  @doc """
  The public API paths an allowed AI crawler may fetch although `/api/` is
  disallowed.
  """
  @spec public_api_paths() :: [String.t()]
  def public_api_paths, do: @public_api_paths

  @doc """
  The body every host but the canonical one gets: everything disallowed for
  every crawler.
  """
  @spec disallow_all() :: String.t()
  def disallow_all, do: "User-agent: *\nDisallow: /\n"

  @doc """
  The body the canonical host gets, with the AI crawler groups following
  `policy`, which defaults to `ai_crawler_policy/0`. It ends with the sitemap,
  whose URL comes from the endpoint, never from the request.
  """
  @spec canonical(policy()) :: String.t()
  def canonical(policy \\ @ai_crawler_policy) when policy in [:allow, :disallow] do
    IO.iodata_to_binary([
      "User-agent: *\nDisallow: /api/\n\n",
      policy_comment(policy),
      Enum.map(@ai_crawlers, &[group(&1, policy), "\n"]),
      "Sitemap: ",
      Endpoint.url(),
      "/sitemap.xml\n"
    ])
  end

  defp policy_comment(:allow), do: "# AI crawlers: allowed, with the rules every crawler has.\n"
  defp policy_comment(:disallow), do: "# AI crawlers: not allowed.\n"

  defp group(user_agent, :allow) do
    [
      "User-agent: ",
      user_agent,
      "\n",
      Enum.map(@public_api_paths, &["Allow: ", &1, "\n"]),
      "Disallow: /api/\n"
    ]
  end

  defp group(user_agent, :disallow), do: ["User-agent: ", user_agent, "\n", "Disallow: /\n"]
end
