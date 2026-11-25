defmodule KanbanWeb.QueuedPatches do
  @moduledoc """
  Makes a LiveView handle several patches back to back, as a slow connection or
  a fast user does.
  """
  import Phoenix.LiveViewTest, only: [render_patch: 2]

  @doc """
  Queues a patch to each URL in the LiveView's mailbox, in order, then lets it
  handle them all and waits for the replies.

  The LiveView is suspended until every patch is queued, so the components of a
  view one URL closes are still there when the next URL opens it, however slow
  or fast the machine is. Returns the view.
  """
  def queue_patches(view, urls) do
    :ok = :sys.suspend(view.pid)

    tasks =
      for url <- urls do
        before = queue_length(view)
        task = Task.async(fn -> render_patch(view, url) end)
        wait_until_queued(view, before)
        task
      end

    :ok = :sys.resume(view.pid)
    Task.await_many(tasks)
    view
  end

  defp wait_until_queued(view, before) do
    unless queue_length(view) > before do
      Process.sleep(1)
      wait_until_queued(view, before)
    end
  end

  defp queue_length(view) do
    {:message_queue_len, length} = Process.info(view.pid, :message_queue_len)
    length
  end
end
