defmodule KanbanWeb.BoardLive.WebhookState do
  @moduledoc """
  What an endpoint row on the board's Integrations view says about the
  endpoint's state: who added it, whether it is Paused or Not sending, and the
  note under it. `KanbanWeb.BoardLive.WebhookViews` renders them.

  `locked?` is true on a free board while paid plans are enforced. Nothing is
  delivered from such a board, and its rows have no enable or disable control,
  so a note there says what to do once the board moves into an Organization.
  Only an endpoint that will send again after that move is Paused: one that is
  switched off stays off until its owner enables it (decided 2026-10-22).

  The gettext calls run inside the function bodies, at render time, so the
  viewer's locale applies.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Webhooks.Endpoint

  @doc """
  "Added by" and the creator's name, or their email when the name is blank;
  `nil` when the creator was not preloaded. The creator is `nil` once their
  account is deleted.
  """
  def added_by(%Endpoint{created_by: %Ecto.Association.NotLoaded{}}), do: nil

  def added_by(%Endpoint{created_by: %{name: name, email: email}}) do
    shown = if is_binary(name) and String.trim(name) != "", do: name, else: email
    gettext("Added by %{name}", name: shown)
  end

  def added_by(%Endpoint{}), do: gettext("Added by a deleted account")

  @doc "Whether the endpoint is on but sends nothing because its creator's account is disabled."
  def not_sending?(%Endpoint{enabled: true, created_by: %{disabled_at: %DateTime{}}}), do: true
  def not_sending?(%Endpoint{}), do: false

  @doc """
  Whether the endpoint is held only by the board's plan, so it sends again
  once the board moves into an Organization.
  """
  def paused?(%Endpoint{enabled: enabled} = endpoint, locked?),
    do: locked? and enabled and not not_sending?(endpoint)

  @doc "The note under the endpoint, or `nil` when there is nothing to explain."
  def note(%Endpoint{enabled: false, disabled_reason: :creator_lost_access}, false) do
    gettext(
      "Switched off automatically because the person who added it no longer has access to this board. Enable it to take it over."
    )
  end

  def note(%Endpoint{enabled: false, disabled_reason: :creator_lost_access}, true) do
    gettext(
      "Switched off automatically because the person who added it no longer has access to this board. After this board moves into an Organization, enable it to take it over."
    )
  end

  def note(%Endpoint{enabled: false}, _locked?), do: nil

  def note(%Endpoint{} = endpoint, locked?) do
    case {not_sending?(endpoint), locked?} do
      {true, false} ->
        gettext(
          "Sends nothing while the account of the person who added it is disabled. Disable and enable it to take it over."
        )

      {true, true} ->
        gettext(
          "Sends nothing while the account of the person who added it is disabled. After this board moves into an Organization, disable and enable it to take it over."
        )

      {false, true} ->
        gettext("Sends again once this board moves into an Organization.")

      {false, false} ->
        nil
    end
  end
end
