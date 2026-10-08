defmodule KanbanWeb.TaskLive.Components.CommentRow do
  @moduledoc """
  Renders one comment of a task's comment thread: avatar, author, relative
  time, edited marker, body (with `@mention` chips) and — when allowed — the
  edit and delete controls or the inline edit form.

  Extracted from `KanbanWeb.TaskLive.CommentThreadComponent`, which owns the
  thread's state and events; this module is markup only. The controls it
  renders are a hint: every event they fire is re-authorized by the thread's
  `Kanban.Tasks` comment functions.
  """
  use KanbanWeb, :html

  alias Kanban.Tasks.Mentions
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.TaskLive.Components.MentionField
  alias KanbanWeb.TimeAgo

  @doc """
  The DOM id of one comment's row inside the thread whose component id is
  `thread_id`.
  """
  def comment_dom_id(thread_id, %{id: comment_id}), do: "#{thread_id}-comment-#{comment_id}"

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
          <MentionField.mention_textarea field={f[:content]} />
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
