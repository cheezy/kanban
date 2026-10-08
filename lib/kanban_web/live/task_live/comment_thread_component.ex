defmodule KanbanWeb.TaskLive.CommentThreadComponent do
  @moduledoc """
  The task comment thread: the list of comments plus the composer and the
  inline edit and delete controls, shared by the task view modal
  (`KanbanWeb.TaskLive.ViewComponent`) and the task edit form
  (`KanbanWeb.TaskLive.FormComponent`) so the two can no longer diverge.

  Each comment shows its author's avatar and name ("Unknown" for legacy rows
  with no author; the agent name plus "via <user>" for comments an agent
  posted through the API), a relative time, and an "edited" marker once
  `edited_at` is set. A `@[Name](user:ID)` mention of a current board member
  renders as a chip showing that member's current name; any other token stays
  plain text.

  Data and permissions come from `Kanban.Tasks.list_comment_thread/2`, which
  resolves the viewer's board access once. The rendered controls are a hint
  only: every event calls the authorizing `Kanban.Tasks` comment functions,
  so a forged event for a control that was never rendered is still refused.

  ## Assigns

    * `id` — use `dom_id/2`, which keeps the two hosts' ids distinct.
    * `task_id` — the task whose comments to show.
    * `current_scope` — the viewer's scope; `nil` renders read-only.

  ## Live refresh

  `refresh/1` re-reads the thread in every host that may have it open. The
  board LiveView calls it when it receives a `:comment_changed` broadcast.
  A refresh keeps an open composer draft and an open edit form, unless the
  comment being edited is gone or no longer editable.
  """
  use KanbanWeb, :live_component

  alias Kanban.Tasks
  alias Kanban.Tasks.Mentions
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.SectionHead
  alias KanbanWeb.TimeAgo

  @hosts [:view, :form]

  @doc """
  The component id for the thread mounted in `host` (`:view` or `:form`).
  """
  def dom_id(host, task_id) when host in @hosts, do: "comment-thread-#{host}-#{task_id}"

  @doc """
  The DOM id of one comment's row inside the thread whose component id is
  `thread_id`.
  """
  def comment_dom_id(thread_id, %{id: comment_id}), do: "#{thread_id}-comment-#{comment_id}"

  @doc """
  Asks every mounted thread for the task in `payload` to reload its comments.

  Accepts the `:comment_changed` broadcast payload (`%{task_id: id}`) or a
  bare task id. Must be called from the LiveView process hosting the
  components; a thread that is not mounted is skipped by LiveView.
  """
  def refresh(%{task_id: task_id}), do: refresh(task_id)

  def refresh(task_id) when is_integer(task_id) do
    Enum.each(@hosts, fn host ->
      send_update(__MODULE__, id: dom_id(host, task_id), refresh: true)
    end)
  end

  def refresh(_payload), do: :ok

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load_thread(socket)}

  @impl true
  def update(%{id: id, task_id: task_id} = assigns, socket) do
    same_task? = Map.get(socket.assigns, :task_id) == task_id

    {:ok,
     socket
     |> assign(:id, id)
     |> assign(:task_id, task_id)
     |> assign(:current_scope, Map.get(assigns, :current_scope))
     |> reset_or_keep_drafts(same_task?)
     |> load_thread()}
  end

  # A re-render for the same task must not wipe a draft or an open edit.
  defp reset_or_keep_drafts(socket, true) do
    socket
    |> assign_new(:comment_form, fn -> new_comment_form(socket.assigns.id) end)
    |> assign_new(:editing_id, fn -> nil end)
    |> assign_new(:edit_form, fn -> nil end)
  end

  defp reset_or_keep_drafts(socket, false) do
    socket
    |> assign(:comment_form, new_comment_form(socket.assigns.id))
    |> clear_editing()
  end

  @impl true
  def handle_event("add_comment", %{"task_comment" => params}, socket) when is_map(params) do
    socket.assigns.current_scope
    |> Tasks.create_comment(task_ref(socket), params)
    |> handle_create_result(socket)
  end

  @impl true
  def handle_event("edit_comment", %{"id" => raw_id}, socket) do
    case find_entry(socket, raw_id) do
      %{can_edit: true, comment: comment} ->
        {:noreply,
         socket
         |> assign(:editing_id, comment.id)
         |> assign(:edit_form, edit_form(TaskComment.changeset(comment, %{}), socket, comment.id))}

      _not_editable ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket), do: {:noreply, clear_editing(socket)}

  # The target is the server-held editing_id, never an id from the client.
  @impl true
  def handle_event("save_comment", %{"task_comment" => params}, socket) when is_map(params) do
    case socket.assigns.editing_id do
      nil ->
        {:noreply, socket}

      editing_id ->
        socket.assigns.current_scope
        |> Tasks.update_comment(%TaskComment{id: editing_id}, params)
        |> handle_save_result(socket, editing_id)
    end
  end

  # The comment must belong to this thread, but whether the viewer may delete
  # it is decided by Tasks.delete_comment/2, not by which buttons rendered.
  @impl true
  def handle_event("delete_comment", %{"id" => raw_id}, socket) do
    case find_entry(socket, raw_id) do
      %{comment: comment} ->
        socket.assigns.current_scope
        |> Tasks.delete_comment(comment)
        |> handle_delete_result(socket)

      nil ->
        {:noreply, comment_gone(socket)}
    end
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The thread scrolls on its own, so the new comment can land below the
  # visible rows; the browser is told to bring it into view (see app.js).
  defp handle_create_result({:ok, comment}, socket) do
    {:noreply,
     socket
     |> assign(:comment_form, new_comment_form(socket.assigns.id))
     |> load_thread()
     |> push_event("comment-thread:scroll-to", %{id: comment_dom_id(socket.assigns.id, comment)})
     |> notify_flash(:info, gettext("Comment added successfully"))}
  end

  defp handle_create_result({:error, %Ecto.Changeset{} = changeset}, socket),
    do: {:noreply, assign(socket, :comment_form, comment_form(changeset, socket.assigns.id))}

  defp handle_create_result({:error, :unauthorized}, socket) do
    {:noreply,
     notify_flash(socket, :error, gettext("You must be a board member to comment on this task"))}
  end

  defp handle_create_result({:error, :not_found}, socket),
    do: {:noreply, socket |> load_thread() |> notify_flash(:error, gettext("Task not found"))}

  defp handle_save_result({:ok, _comment}, socket, _editing_id),
    do: {:noreply, socket |> clear_editing() |> load_thread()}

  defp handle_save_result({:error, %Ecto.Changeset{} = changeset}, socket, editing_id),
    do: {:noreply, assign(socket, :edit_form, edit_form(changeset, socket, editing_id))}

  defp handle_save_result({:error, :not_found}, socket, _editing_id),
    do: {:noreply, comment_gone(socket)}

  defp handle_save_result({:error, :unauthorized}, socket, _editing_id),
    do: {:noreply, not_allowed(socket)}

  defp handle_delete_result({:ok, _comment}, socket), do: {:noreply, load_thread(socket)}
  defp handle_delete_result({:error, :not_found}, socket), do: {:noreply, comment_gone(socket)}
  defp handle_delete_result({:error, :unauthorized}, socket), do: {:noreply, not_allowed(socket)}

  defp comment_gone(socket) do
    socket
    |> clear_editing()
    |> load_thread()
    |> notify_flash(:error, gettext("This comment no longer exists"))
  end

  defp not_allowed(socket) do
    socket
    |> clear_editing()
    |> load_thread()
    |> notify_flash(:error, gettext("You are not allowed to change this comment"))
  end

  # LiveView discards a live component's own flash unless the component also
  # redirects or patches, so the message goes to the hosting LiveView, which
  # owns the flash and handles {CommentThreadComponent, {:flash, kind, message}}.
  defp notify_flash(socket, kind, message) do
    send(self(), {__MODULE__, {:flash, kind, message}})
    socket
  end

  defp load_thread(socket) do
    case Tasks.list_comment_thread(socket.assigns.current_scope, task_ref(socket)) do
      {:ok, %{can_comment: can_comment, entries: entries}} ->
        socket
        |> assign(:can_comment, can_comment)
        |> assign(:entries, entries)
        |> keep_editing_if_still_editable()

      {:error, :not_found} ->
        socket
        |> assign(:can_comment, false)
        |> assign(:entries, [])
        |> clear_editing()
    end
  end

  defp keep_editing_if_still_editable(%{assigns: %{editing_id: nil}} = socket), do: socket

  defp keep_editing_if_still_editable(socket) do
    editing_id = socket.assigns.editing_id

    if Enum.any?(socket.assigns.entries, &(&1.comment.id == editing_id and &1.can_edit)),
      do: socket,
      else: clear_editing(socket)
  end

  defp clear_editing(socket) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:edit_form, nil)
  end

  defp find_entry(socket, raw_id) when is_binary(raw_id) do
    case Integer.parse(raw_id) do
      {id, ""} -> Enum.find(socket.assigns.entries, &(&1.comment.id == id))
      _invalid -> nil
    end
  end

  defp find_entry(_socket, _raw_id), do: nil

  defp task_ref(socket), do: %Task{id: socket.assigns.task_id}

  defp new_comment_form(id), do: comment_form(TaskComment.changeset(%TaskComment{}, %{}), id)

  defp comment_form(changeset, id), do: to_form(changeset, id: "#{id}-composer")

  defp edit_form(changeset, socket, comment_id),
    do: to_form(changeset, id: "#{socket.assigns.id}-edit-#{comment_id}")

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} data-comment-thread>
      <SectionHead.section_head title={gettext("Comments")} count_label={count_label(@entries)} />

      <p
        :if={@entries == []}
        style="margin: 0; font-size: 12px; color: var(--ink-3); font-style: italic;"
      >
        {gettext("No comments yet")}
      </p>

      <div
        :if={@entries != []}
        style="display: flex; flex-direction: column; gap: 14px; max-height: 28rem; overflow-y: auto;"
      >
        <.comment_row
          :for={entry <- @entries}
          entry={entry}
          editing={entry.comment.id == @editing_id}
          edit_form={@edit_form}
          target={@myself}
          dom_prefix={@id}
        />
      </div>

      <.form
        :let={f}
        :if={@can_comment}
        for={@comment_form}
        id={"#{@id}-composer"}
        phx-target={@myself}
        phx-submit="add_comment"
        style="margin-top: 16px;"
      >
        <.input
          field={f[:content]}
          type="textarea"
          label={gettext("Add a comment")}
          rows="3"
          maxlength={TaskComment.content_max_length()}
          placeholder={gettext("Write your comment here...")}
          required
        />
        <div style="margin-top: 8px;">
          <.button type="submit" phx-disable-with={gettext("Adding...")}>
            {gettext("Add Comment")}
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  @doc """
  Renders one comment: avatar, author, relative time, edited marker, body,
  and — when allowed — the edit and delete controls or the inline edit form.

  `entry` is one element of `Kanban.Tasks.list_comment_thread/2`'s `entries`.
  Content is split into text and mention segments by
  `Kanban.Tasks.Mentions.segments/2`, using the entry's `mentions` map, and
  every segment is rendered through HEEx and therefore always escaped.
  """
  attr :entry, :map, required: true
  attr :editing, :boolean, default: false
  attr :edit_form, :any, default: nil
  attr :target, :any, default: nil
  attr :dom_prefix, :string, default: "comment-thread"

  def comment_row(assigns) do
    comment = assigns.entry.comment
    inserted_at = to_utc(comment.inserted_at)

    assigns =
      assigns
      |> assign(:comment, comment)
      |> assign(:author, author_details(comment))
      |> assign(:inserted_at, inserted_at)
      |> assign(:age, TimeAgo.format_age(inserted_at, :coarse))
      |> assign(
        :segments,
        Mentions.segments(comment.content, Map.get(assigns.entry, :mentions, %{}))
      )

    ~H"""
    <article
      id={comment_dom_id(@dom_prefix, @comment)}
      data-comment
      style="display: flex; align-items: flex-start; gap: 10px;"
    >
      <span style="margin-top: 1px; flex-shrink: 0; display: inline-flex;">
        <Avatar.avatar kind={@author.kind} name={@author.name} palette={@author.palette} size={22} />
      </span>
      <div style="flex: 1; min-width: 0;">
        <div style="display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 8px; font-size: 12px;">
          <span
            data-comment-author
            style="font-weight: 600; color: var(--ink); overflow-wrap: anywhere;"
          >
            {@author.name}
          </span>
          <span
            :if={@author.via}
            data-comment-via
            style="color: var(--ink-3); overflow-wrap: anywhere;"
          >
            {gettext("via %{name}", name: @author.via)}
          </span>
          <time
            :if={@inserted_at}
            datetime={DateTime.to_iso8601(@inserted_at)}
            title={Calendar.strftime(@inserted_at, "%Y-%m-%d %H:%M UTC")}
            style="font-size: 11px; color: var(--ink-3); font-family: var(--font-mono);"
          >
            {@age}
          </time>
          <span
            :if={@comment.edited_at}
            data-comment-edited
            title={Calendar.strftime(@comment.edited_at, "%Y-%m-%d %H:%M UTC")}
            style="font-size: 11px; color: var(--ink-3); font-style: italic;"
          >
            {gettext("edited")}
          </span>
          <span style="flex: 1;"></span>
          <span :if={!@editing} style="display: inline-flex; gap: 4px;">
            <%!-- Compact ghost variant of <.button>: a full-size button per
            comment row would dominate the thread. --%>
            <.button
              :if={@entry.can_edit}
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="edit_comment"
              phx-value-id={@comment.id}
              phx-target={@target}
              style="color: var(--ink-2);"
            >
              {gettext("Edit")}
            </.button>
            <.button
              :if={@entry.can_delete}
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="delete_comment"
              phx-value-id={@comment.id}
              phx-target={@target}
              data-confirm={gettext("Are you sure you want to delete this comment?")}
              style="color: var(--st-blocked);"
            >
              {gettext("Delete")}
            </.button>
          </span>
        </div>

        <.form
          :let={f}
          :if={@editing && @edit_form}
          for={@edit_form}
          id={"#{@dom_prefix}-edit-#{@comment.id}"}
          phx-target={@target}
          phx-submit="save_comment"
          style="margin-top: 6px;"
        >
          <.input
            field={f[:content]}
            type="textarea"
            rows="3"
            maxlength={TaskComment.content_max_length()}
            required
          />
          <div style="display: flex; gap: 8px; margin-top: 6px;">
            <.button type="submit" phx-disable-with={gettext("Saving...")}>
              {gettext("Save")}
            </.button>
            <.button type="button" phx-click="cancel_edit" phx-target={@target}>
              {gettext("Cancel")}
            </.button>
          </div>
        </.form>

        <%!-- white-space: pre-wrap keeps the comment's own line breaks, so the
        content must touch both tags: any template whitespace inside them is
        rendered as a leading blank line and indent. phx-no-format stops
        mix format from moving the content back onto its own line, and the
        segments are emitted with no whitespace between them. --%>
        <p
          :if={!@editing}
          data-comment-body
          phx-no-format
          style="margin: 4px 0 0; font-size: 12.5px; line-height: 1.5; color: var(--ink); white-space: pre-wrap; overflow-wrap: anywhere;"
        ><.comment_segment :for={segment <- @segments} segment={segment} /></p>
      </div>
    </article>
    """
  end

  attr :segment, :any, required: true

  # One piece of a comment body. Text is emitted bare (no wrapping tag, no
  # whitespace) so pre-wrap shows exactly the comment's own characters.
  defp comment_segment(%{segment: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  defp comment_segment(%{segment: {:mention, user_id, name}} = assigns) do
    assigns =
      assigns
      |> assign(:user_id, user_id)
      |> assign(:name, name)
      |> assign(:palette, AvatarPalette.for_human(user_id))

    ~H"""
    <span
      data-mention-chip
      data-user-id={@user_id}
      style="display: inline-flex; align-items: center; gap: 3px; vertical-align: baseline; padding: 0 5px; border-radius: 4px; background: var(--st-ready-soft); border: 1px solid var(--line); color: var(--ink); font-weight: 600; white-space: nowrap;"
    ><Avatar.avatar kind={:human} name={@name} palette={@palette} size={14} />@{@name}</span>
    """
  end

  defp count_label([]), do: nil
  defp count_label(entries), do: entries |> length() |> Integer.to_string()

  # An agent comment is attributed to the agent and to the human whose token
  # it ran under; anything else to its human author, or "Unknown" when the
  # row predates authorship.
  defp author_details(%TaskComment{author_agent_name: agent} = comment)
       when is_binary(agent) and agent != "" do
    %{
      kind: :agent,
      name: agent,
      palette: AvatarPalette.for_agent(agent),
      via: display_name(comment.author)
    }
  end

  defp author_details(%TaskComment{author: author}) do
    %{
      kind: :human,
      name: display_name(author),
      palette: author |> author_id() |> AvatarPalette.for_human(),
      via: nil
    }
  end

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{email: email}) when is_binary(email) and email != "", do: email
  defp display_name(_author), do: gettext("Unknown")

  defp author_id(%{id: id}) when is_integer(id), do: id
  defp author_id(_author), do: nil

  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_utc(%DateTime{} = datetime), do: datetime
  defp to_utc(_missing), do: nil
end
