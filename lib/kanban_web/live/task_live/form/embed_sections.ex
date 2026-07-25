defmodule KanbanWeb.TaskLive.Form.EmbedSections do
  @moduledoc """
  The task form's three embed repeaters — `key_files`, `verification_steps` and
  `behaviour_test_matrix` — extracted from `form_component.html.heex` (which was
  well over the module-size guidance in `AGENTS.md`).

  All three share one shape: a visibility gate, a top-level `<.error>` for the
  embed field, an `<.inputs_for>` row list with a hidden `position`, and
  add/remove buttons targeting the parent LiveComponent.
  """
  use KanbanWeb, :html

  alias KanbanWeb.TaskLive.Form.OptionBuilders

  attr :f, Phoenix.HTML.Form, required: true
  attr :field_visibility, :map, required: true
  attr :myself, :any, required: true

  def embed_sections(assigns) do
    ~H"""
    <%= if field_visible?(@field_visibility, "key_files") do %>
      <%!-- Key Files Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Key Files to Read First")}
        </h3>
        <.error :for={msg <- Enum.map(@f[:key_files].errors, &translate_error/1)}>{msg}</.error>
        <.inputs_for :let={kf} field={@f[:key_files]}>
          <div class="flex flex-wrap gap-2 items-start mb-2">
            <div class="flex-1">
              <.input
                field={kf[:file_path]}
                type="text"
                placeholder={gettext("lib/kanban/tasks.ex")}
              />
            </div>
            <div class="flex-1">
              <.input
                field={kf[:note]}
                type="text"
                placeholder={gettext("Note about this file")}
              />
            </div>
            <input type="hidden" name={kf[:position].name} value={kf[:position].value} />
            <button
              type="button"
              phx-click="remove-key-file"
              phx-value-index={kf.index}
              phx-target={@myself}
              style="margin-top: 32px; padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
            >
              {gettext("Remove")}
            </button>
          </div>
        </.inputs_for>
        <button
          type="button"
          phx-click="add-key-file"
          phx-target={@myself}
          style="padding: 6px 14px; font-size: 12px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
        >
          + {gettext("Add Key File")}
        </button>
      </div>
    <% end %>

    <%= if field_visible?(@field_visibility, "verification_steps") do %>
      <%!-- Verification Steps Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Verification Steps")}
        </h3>
        <.error :for={msg <- Enum.map(@f[:verification_steps].errors, &translate_error/1)}>
          {msg}
        </.error>
        <.inputs_for :let={vs} field={@f[:verification_steps]}>
          <div class="flex flex-wrap gap-2 items-start mb-2">
            <div class="w-32">
              <.input
                field={vs[:step_type]}
                type="select"
                options={[{gettext("Command"), "command"}, {gettext("Manual"), "manual"}]}
              />
            </div>
            <div class="flex-1">
              <.input field={vs[:step_text]} type="text" placeholder={gettext("mix test")} />
            </div>
            <div class="flex-1">
              <.input
                field={vs[:expected_result]}
                type="text"
                placeholder={gettext("Expected result")}
              />
            </div>
            <input type="hidden" name={vs[:position].name} value={vs[:position].value} />
            <button
              type="button"
              phx-click="remove-verification-step"
              phx-value-index={vs.index}
              phx-target={@myself}
              style="margin-top: 32px; padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
            >
              {gettext("Remove")}
            </button>
          </div>
        </.inputs_for>
        <button
          type="button"
          phx-click="add-verification-step"
          phx-target={@myself}
          style="padding: 6px 14px; font-size: 12px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
        >
          + {gettext("Add Verification Step")}
        </button>
      </div>
    <% end %>

    <%= if field_visible?(@field_visibility, "behaviour_test_matrix") do %>
      <%!-- Behaviour/Test Matrix Section --%>
      <div style="margin-top: 24px; padding-top: 18px; border-top: 1px solid var(--line);">
        <h3 style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin: 0 0 12px;">
          {gettext("Behaviour/Test Matrix")}
        </h3>
        <p style="font-size: 11.5px; color: var(--ink-3); margin: 0 0 12px;">
          {gettext(
            "Cover every category at least once. Give each row a real test name, or set the status to Not applicable and say why."
          )}
        </p>
        <.error :for={msg <- Enum.map(@f[:behaviour_test_matrix].errors, &translate_error/1)}>
          {msg}
        </.error>
        <div
          :if={Enum.any?(@f[:behaviour_test_matrix].value || [])}
          class="hidden sm:flex flex-wrap gap-2 items-end mb-1"
          style="font-size: 9.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3);"
        >
          <div class="w-44">{gettext("Category")}</div>
          <div class="flex-1">{gettext("Behaviour to verify")}</div>
          <div class="flex-1">{gettext("planned test name")}</div>
          <div class="w-32">{gettext("Type")}</div>
          <div class="w-36">{gettext("Status")}</div>
          <div class="flex-1">{gettext("Why not applicable?")}</div>
        </div>
        <.inputs_for :let={row} field={@f[:behaviour_test_matrix]}>
          <div class="flex flex-wrap gap-2 items-start mb-2">
            <div class="w-44">
              <.input
                field={row[:category]}
                type="select"
                options={OptionBuilders.build_behaviour_test_category_options()}
                prompt={gettext("Category")}
              />
            </div>
            <div class="flex-1">
              <.input
                field={row[:behaviour]}
                type="text"
                placeholder={gettext("Behaviour to verify")}
              />
            </div>
            <div class="flex-1">
              <.input
                field={row[:test_name]}
                type="text"
                placeholder={gettext("planned test name")}
              />
            </div>
            <div class="w-32">
              <.input field={row[:type]} type="text" placeholder={gettext("unit / manual")} />
            </div>
            <div class="w-36">
              <.input
                field={row[:status]}
                type="select"
                options={OptionBuilders.build_behaviour_test_status_options()}
              />
            </div>
            <div class="flex-1">
              <.input
                field={row[:na_reason]}
                type="text"
                placeholder={gettext("Why not applicable?")}
              />
            </div>
            <input type="hidden" name={row[:position].name} value={row[:position].value} />
            <button
              type="button"
              phx-click="remove-behaviour-test-row"
              phx-value-index={row.index}
              phx-target={@myself}
              style="margin-top: 32px; padding: 6px 12px; font-size: 11.5px; font-weight: 500; background: var(--st-blocked-soft); color: var(--st-blocked); border: 1px solid var(--st-blocked-soft); border-radius: 6px; cursor: pointer;"
            >
              {gettext("Remove")}
            </button>
          </div>
        </.inputs_for>
        <button
          type="button"
          phx-click="add-behaviour-test-row"
          phx-target={@myself}
          style="padding: 6px 14px; font-size: 12px; font-weight: 500; background: var(--surface); color: var(--ink-2); border: 1px solid var(--line); border-radius: 6px; cursor: pointer;"
        >
          + {gettext("Add Behaviour Row")}
        </button>
      </div>
    <% end %>
    """
  end

  defp field_visible?(field_visibility, field_name) do
    Map.get(field_visibility, field_name, false)
  end
end
