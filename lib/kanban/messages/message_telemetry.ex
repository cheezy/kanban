defmodule Kanban.Messages.MessageTelemetry do
  @moduledoc """
  Emits the admin broadcast message telemetry events through
  `Kanban.Telemetry`.

  Every event is emitted only after the change it reports has been saved, so
  an invalid message emits nothing, and a repeated dismissal, which saves no
  new row, emits nothing either. The functions take a result and return it
  unchanged, so they can sit at the end of a pipe without changing what the
  caller sees. Metadata carries ids only; a message's title and body are
  never sent.
  """

  alias Kanban.Messages.Message
  alias Kanban.Messages.MessageDismissal

  @doc """
  Emits `[:kanban, :message, :created]` when `result` is a saved message.
  Returns `result`.
  """
  @spec created(result) :: result when result: term()
  def created({:ok, %Message{} = message} = result) do
    Kanban.Telemetry.emit([:kanban, :message, :created], %{count: 1}, %{
      message_id: message.id,
      sender_user_id: message.sender_id
    })

    result
  end

  def created(result), do: result

  @doc """
  Emits `[:kanban, :message, :deleted]` when `result` is a deleted message.
  Returns `result`.
  """
  @spec deleted(result) :: result when result: term()
  def deleted({:ok, %Message{} = message} = result) do
    Kanban.Telemetry.emit([:kanban, :message, :deleted], %{count: 1}, %{
      message_id: message.id,
      sender_user_id: message.sender_id
    })

    result
  end

  def deleted(result), do: result

  @doc """
  Emits `[:kanban, :message, :dismissed]` when `result` is a newly saved
  dismissal. A repeated dismissal comes back without an id and emits
  nothing. Returns `result`.
  """
  @spec dismissed(result) :: result when result: term()
  def dismissed({:ok, %MessageDismissal{id: id} = dismissal} = result) when not is_nil(id) do
    Kanban.Telemetry.emit([:kanban, :message, :dismissed], %{count: 1}, %{
      message_id: dismissal.message_id,
      user_id: dismissal.user_id
    })

    result
  end

  def dismissed(result), do: result
end
