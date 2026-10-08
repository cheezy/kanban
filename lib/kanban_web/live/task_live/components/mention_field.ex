defmodule KanbanWeb.TaskLive.Components.MentionField do
  @moduledoc """
  The comment textarea with `@mention` autocomplete, used by the comment
  thread's composer and its inline edit form.

  The textarea carries the `MentionAutocomplete` hook
  (`assets/js/hooks/mention_autocomplete.js`). Typing `@` at the start of the
  text or after whitespace makes the hook ask the hosting
  `KanbanWeb.TaskLive.CommentThreadComponent` for matching board members
  (its `mention_search` event) and list them in the sibling listbox, from
  which the canonical `@[Name](user:ID)` token is inserted.

  The listbox is rendered here, not by the hook, so its accessible name and
  empty-state text are translated server-side; the hook reads the empty-state
  text from `data-empty-text`. `phx-update="ignore"` keeps the options the
  hook adds across LiveView patches.
  """
  use KanbanWeb, :html

  alias Kanban.Tasks.TaskComment

  @doc """
  Renders the comment textarea for `field` with its mention listbox.

  The listbox id is the textarea id plus `-mentions`, and the textarea names
  it through `aria-controls` and `data-mention-listbox`.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: nil
  attr :placeholder, :string, default: nil

  def mention_textarea(assigns) do
    assigns = assign(assigns, :listbox_id, listbox_id(assigns.field))

    ~H"""
    <div data-mention-field style="position: relative;">
      <.input
        field={@field}
        type="textarea"
        label={@label}
        rows="3"
        maxlength={TaskComment.content_max_length()}
        placeholder={@placeholder}
        required
        autocomplete="off"
        phx-hook="MentionAutocomplete"
        role="combobox"
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-autocomplete="list"
        aria-controls={@listbox_id}
        data-mention-listbox={@listbox_id}
      />
      <ul
        id={@listbox_id}
        role="listbox"
        class="mention-listbox"
        aria-label={gettext("Board members")}
        data-empty-text={gettext("No matching members")}
        phx-update="ignore"
        hidden
      >
      </ul>
    </div>
    """
  end

  @doc """
  The DOM id of the mention listbox belonging to the textarea for `field`.
  """
  def listbox_id(%Phoenix.HTML.FormField{id: id}), do: id <> "-mentions"
end
