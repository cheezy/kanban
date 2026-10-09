defmodule KanbanWeb.TaskLive.Form.LabelPicker do
  @moduledoc """
  The task form's label picker (W2234): one checkbox per label on the current
  board, each shown as its `KanbanWeb.LabelChip` chip. Selection state lives
  in the form component's assigns and is resolved on save by
  `KanbanWeb.TaskLive.Form.LabelSelection`.

  Raw checkboxes rather than core_components' `<.input type="checkbox">`, for
  the reason given in `KanbanWeb.MetricsLive.Workspace`: `<.input>` emits a
  hidden `"false"` companion for a single boolean field, which would inject
  `"false"` into the shared `task[label_ids][]` array. The group's own hidden
  `""` sentinel makes an empty selection post as a key, so unchecking every
  label clears them.
  """
  use KanbanWeb, :html

  alias KanbanWeb.LabelChip

  attr :labels, :list, required: true, doc: "`%{id, name, color}` maps for this board"
  attr :selected, :list, required: true, doc: "the checked label ids"

  def label_picker(assigns) do
    ~H"""
    <fieldset data-label-picker class="fieldset mb-2" style="border: 0; padding: 0; margin: 0;">
      <legend class="label mb-1">{gettext("Labels")}</legend>
      <p :if={@labels == []} style="margin: 0; font-size: 12.5px; color: var(--ink-3);">
        {gettext("This board has no labels yet.")}
      </p>
      <div :if={@labels != []} style="display: flex; flex-wrap: wrap; gap: 6px 12px;">
        <input type="hidden" name="task[label_ids][]" value="" />
        <label
          :for={label <- @labels}
          style="display: inline-flex; align-items: center; gap: 6px; min-width: 0; cursor: pointer;"
        >
          <input
            type="checkbox"
            name="task[label_ids][]"
            value={label.id}
            checked={label.id in @selected}
            class="checkbox checkbox-sm"
          />
          <LabelChip.label_chip label={label} />
        </label>
      </div>
    </fieldset>
    """
  end
end
