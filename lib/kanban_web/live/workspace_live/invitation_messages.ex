defmodule KanbanWeb.WorkspaceLive.InvitationMessages do
  @moduledoc """
  The user-facing outcome messages of accepting an invitation (W2219), shared
  by `KanbanWeb.WorkspaceLive.InvitationAccept` and the email confirmation
  page, which accepts an invitation the new account registered from.

  Every refusal except a full board is one generic message, so the page never
  tells a visitor whether a token exists, has expired, was revoked or used, or
  was sent to another address, nor that the invitee belongs to another
  Organization.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @doc "The one message for every invalid invitation state."
  @spec invalid() :: String.t()
  def invalid, do: gettext("This invitation link is invalid or has expired.")

  @doc "The message for a board that is at its free-plan member cap."
  @spec board_full() :: String.t()
  def board_full do
    gettext(
      "This board is full: free boards hold %{cap} people. Ask the board owner to make room, then open the link again.",
      cap: Kanban.Plans.free_board_member_cap()
    )
  end

  @doc "The confirmation shown once an invitation was accepted."
  @spec joined(map()) :: String.t()
  def joined(%{board: %{name: name}}) when is_binary(name),
    do: gettext("You joined %{name}.", name: name)

  def joined(%{workspace: %{name: name}}) when is_binary(name),
    do: gettext("You joined %{name}.", name: name)

  def joined(_result), do: gettext("Invitation accepted.")

  @doc "The flash for an acceptance result, as `{kind, message}`."
  @spec flash({:ok, map()} | {:error, atom()}) :: {:info | :error, String.t()}
  def flash({:ok, result}), do: {:info, joined(result)}
  def flash({:error, :member_cap_reached}), do: {:error, board_full()}
  def flash({:error, _reason}), do: {:error, invalid()}
end
