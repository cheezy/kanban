defmodule KanbanWeb.OAuthHTML do
  @moduledoc """
  The device sign-in confirmation page (`KanbanWeb.OAuthController`). It
  renders in the standalone auth frame rather than `Layouts.app`, so the page
  is only the question and its two answers.
  """

  use KanbanWeb, :html

  import KanbanWeb.AuthFrame

  embed_templates "oauth_html/*"

  @doc "The icon for a validated request's `device_class` hint."
  @spec device_icon(String.t()) :: String.t()
  def device_icon("tablet"), do: "hero-device-tablet"
  def device_icon(_device_class), do: "hero-device-phone-mobile"
end
