defmodule KanbanWeb.CompareHTML do
  @moduledoc """
  Templates for `KanbanWeb.CompareController`. See the `compare_html`
  directory.
  """
  use KanbanWeb, :html

  embed_templates "compare_html/*"

  @doc """
  A URL without its scheme, for link text.
  """
  @spec display_url(String.t()) :: String.t()
  def display_url(url), do: String.replace_prefix(url, "https://", "")

  @doc """
  Where to report a claim that has gone out of date.
  """
  @spec issues_url() :: String.t()
  def issues_url, do: KanbanWeb.MarketingClosing.github_url() <> "/issues"
end
