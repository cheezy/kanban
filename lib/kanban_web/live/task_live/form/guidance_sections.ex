defmodule KanbanWeb.TaskLive.Form.GuidanceSections do
  @moduledoc """
  The task form's plain string-list sections — `technology_requirements`,
  `pitfalls`, `out_of_scope` and `security_considerations` — extracted from `form_component.html.heex` (which
  was well over the module-size guidance in `AGENTS.md`).

  Each edits a `{:array, :string}` column as a list of text inputs with
  add/remove buttons targeting the parent LiveComponent.
  """
  use KanbanWeb, :html

  attr :f, Phoenix.HTML.Form, required: true
  attr :field_visibility, :map, required: true
  attr :myself, :any, required: true

  def guidance_sections(assigns) do
    ~H"""
    <%= if field_visible?(@field_visibility, "technology_requirements") do %>
      <%!-- Technology Requirements Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Technology Requirements")}
        </h3>
        <.error :for={msg <- Enum.map(@f[:technology_requirements].errors, &translate_error/1)}>
          {msg}
        </.error>
        <input type="hidden" name="task[technology_requirements][]" value="" />
        <%= for {tech, index} <- Enum.with_index(Ecto.Changeset.get_field(@f.source, :technology_requirements) || []) do %>
          <div class="flex gap-2 mb-2">
            <input
              type="text"
              name="task[technology_requirements][]"
              value={tech}
              placeholder={gettext("Technology/library name")}
              style="flex: 1; padding: 6px 10px; font-size: 13px; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
            />
            <button
              type="button"
              phx-click="remove-technology"
              phx-value-index={index}
              phx-target={@myself}
              style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
            >
              {gettext("Remove")}
            </button>
          </div>
        <% end %>
        <button
          type="button"
          phx-click="add-technology"
          phx-target={@myself}
          style="padding: 6px 14px; font-size: 12px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
        >
          + {gettext("Add Technology")}
        </button>
      </div>
    <% end %>
    <%= if field_visible?(@field_visibility, "pitfalls") do %>
      <%!-- Pitfalls Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Common Pitfalls")}
        </h3>
        <.error :for={msg <- Enum.map(@f[:pitfalls].errors, &translate_error/1)}>{msg}</.error>
        <input type="hidden" name="task[pitfalls][]" value="" />
        <%= for {pitfall, index} <- Enum.with_index(Ecto.Changeset.get_field(@f.source, :pitfalls) || []) do %>
          <div class="flex gap-2 mb-2">
            <input
              type="text"
              name="task[pitfalls][]"
              value={pitfall}
              placeholder={gettext("Common pitfall to avoid")}
              style="flex: 1; padding: 6px 10px; font-size: 13px; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
            />
            <button
              type="button"
              phx-click="remove-pitfall"
              phx-value-index={index}
              phx-target={@myself}
              style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
            >
              {gettext("Remove")}
            </button>
          </div>
        <% end %>
        <button
          type="button"
          phx-click="add-pitfall"
          phx-target={@myself}
          style="padding: 6px 14px; font-size: 12px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
        >
          + {gettext("Add Pitfall")}
        </button>
      </div>
    <% end %>

    <%= if field_visible?(@field_visibility, "out_of_scope") do %>
      <%!-- Out of Scope Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Out of Scope")}
        </h3>
        <.error :for={msg <- Enum.map(@f[:out_of_scope].errors, &translate_error/1)}>{msg}</.error>
        <input type="hidden" name="task[out_of_scope][]" value="" />
        <%= for {item, index} <- Enum.with_index(Ecto.Changeset.get_field(@f.source, :out_of_scope) || []) do %>
          <div class="flex gap-2 mb-2">
            <input
              type="text"
              name="task[out_of_scope][]"
              value={item}
              placeholder={gettext("Out of scope item")}
              style="flex: 1; padding: 6px 10px; font-size: 13px; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
            />
            <button
              type="button"
              phx-click="remove-out-of-scope"
              phx-value-index={index}
              phx-target={@myself}
              style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
            >
              {gettext("Remove")}
            </button>
          </div>
        <% end %>
        <button
          type="button"
          phx-click="add-out-of-scope"
          phx-target={@myself}
          style="padding: 6px 14px; font-size: 12px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
        >
          + {gettext("Add Out of Scope Item")}
        </button>
      </div>
    <% end %>

    <%= if field_visible?(@field_visibility, "security_considerations") do %>
      <%!-- Security Considerations Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Security Considerations")}
        </h3>
        <.error :for={msg <- Enum.map(@f[:security_considerations].errors, &translate_error/1)}>
          {msg}
        </.error>
        <input type="hidden" name="task[security_considerations][]" value="" />
        <%= for {item, index} <- Enum.with_index(Ecto.Changeset.get_field(@f.source, :security_considerations) || []) do %>
          <div class="flex gap-2 mb-2">
            <input
              type="text"
              name="task[security_considerations][]"
              value={item}
              placeholder={gettext("Security consideration or requirement")}
              style="flex: 1; padding: 6px 10px; font-size: 13px; color: var(--ink); background: var(--surface); border: 1px solid var(--line); border-radius: 6px;"
            />
            <button
              type="button"
              phx-click="remove-security-consideration"
              phx-value-index={index}
              phx-target={@myself}
              style="padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
            >
              {gettext("Remove")}
            </button>
          </div>
        <% end %>
        <button
          type="button"
          phx-click="add-security-consideration"
          phx-target={@myself}
          style="padding: 6px 14px; font-size: 12px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
        >
          + {gettext("Add Security Consideration")}
        </button>
      </div>
    <% end %>
    """
  end

  defp field_visible?(field_visibility, field_name) do
    Map.get(field_visibility, field_name, false)
  end
end
