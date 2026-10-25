defmodule KanbanWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use KanbanWeb, :html

  import KanbanWeb.MarketingClosing
  import KanbanWeb.MarketingComponents

  embed_templates "page_html/*"

  @changelog_body_path Path.expand("../../../priv/changelog/body.html", __DIR__)
  @external_resource @changelog_body_path
  @changelog_body File.read!(@changelog_body_path)

  @doc """
  Returns the rendered HTML body of the changelog page (the per-release
  `<section>` elements), stored verbatim in `priv/changelog/body.html`.

  The body is developer-facing release notes — kept out of HEEX so it does not
  generate hundreds of fragmented gettext msgids that would never be
  translated. Mirrors the data-as-content pattern used by `HowToData`.
  """
  def changelog_body, do: @changelog_body

  @mcp_snippet String.trim_trailing(~S"""
               export STRIDE_URL="https://your-stride-host"
               export STRIDE_API_TOKEN="paste-your-token-here"
               claude mcp add --transport http stride "${STRIDE_URL}/api/mcp" \
                 --header "Authorization: Bearer ${STRIDE_API_TOKEN}"
               """)

  @doc """
  Returns the shell commands the `/product` Operate theme shows for adding
  Stride's MCP server to Claude Code.

  The commands are kept out of HEEX because `{` starts an interpolation there,
  and they are not translated: they use a placeholder host and token, never a
  real address or a real token.
  """
  def mcp_snippet, do: @mcp_snippet
end
