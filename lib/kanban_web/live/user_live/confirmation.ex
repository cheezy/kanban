defmodule KanbanWeb.UserLive.Confirmation do
  use KanbanWeb, :live_view

  import KanbanWeb.AuthFrame

  alias Kanban.Accounts
  alias KanbanWeb.OnboardingPlugins

  @impl true
  def render(assigns) do
    ~H"""
    <.auth_frame flash={@flash}>
      <div style="display: flex; flex-direction: column; align-items: center; text-align: center;">
        <div style="width: 72px; height: 72px; border-radius: 16px; background: linear-gradient(135deg, var(--stride-orange-soft) 0%, var(--stride-violet-soft) 100%); display: inline-flex; align-items: center; justify-content: center; color: var(--stride-orange-ink); box-shadow: inset 0 0 0 1px var(--line);">
          <svg
            width="34"
            height="34"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            xmlns="http://www.w3.org/2000/svg"
          >
            <rect x="3" y="6" width="18" height="13" rx="2" />
            <path d="M3 8l9 6 9-6" />
          </svg>
        </div>

        <%= if @confirmed do %>
          <h1 style="margin: 20px 0 0; font-size: 28px; font-weight: 600; letter-spacing: -0.025em; line-height: 1.15;">
            {gettext("Your account is confirmed")}
          </h1>

          <p style="margin: 10px 0 0; font-size: 13.5px; color: var(--ink-3); max-width: 360px; text-wrap: pretty;">
            {gettext("You're all set. Follow these steps to get up and running.")}
          </p>

          <div style="margin-top: 24px; width: 100%; text-align: left;">
            <div style="font-family: var(--font-mono); font-size: 10.5px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--ink-3); margin-bottom: 12px;">
              {gettext("Getting started")}
            </div>

            <ol
              role="list"
              style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 14px;"
            >
              <.onboarding_step number="1" title={gettext("Set up your coding agent")}>
                {gettext("Paste this prompt into your agent to configure Stride in your project:")}
                <span style="display: flex; gap: 8px; align-items: flex-start; margin-top: 6px;">
                  <code
                    id="agent-onboarding-prompt"
                    style="flex: 1; padding: 6px 10px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-strong); color: var(--ink); font-family: var(--font-mono); font-size: 11px; line-height: 1.5; word-break: break-word;"
                  >
                    {agent_onboarding_prompt()}
                  </code>
                  <button
                    type="button"
                    data-token-value={agent_onboarding_prompt()}
                    data-copy-text={gettext("Copy")}
                    data-copied-text={"✓ " <> gettext("Copied!")}
                    data-failed-msg={gettext("Failed to copy")}
                    onclick="
                      const text = this.getAttribute('data-token-value');
                      const copiedText = this.getAttribute('data-copied-text');
                      const copyText = this.getAttribute('data-copy-text');
                      const failedMsg = this.getAttribute('data-failed-msg');
                      const textarea = document.createElement('textarea');
                      textarea.value = text;
                      textarea.style.position = 'fixed';
                      textarea.style.opacity = '0';
                      document.body.appendChild(textarea);
                      textarea.select();
                      try {
                        document.execCommand('copy');
                        this.innerHTML = copiedText;
                        setTimeout(() => { this.innerHTML = copyText; }, 2000);
                      } catch (err) {
                        alert(failedMsg + ': ' + err.message);
                      } finally {
                        document.body.removeChild(textarea);
                      }
                    "
                    style="padding: 6px 12px; border-radius: 5px; border: none; background: var(--ink); color: var(--surface); font-size: 12px; font-weight: 500; cursor: pointer; flex-shrink: 0;"
                  >
                    {gettext("Copy")}
                  </button>
                </span>
              </.onboarding_step>

              <.onboarding_step rich number="2" title={gettext("Install the Stride plugin")}>
                {gettext(
                  "Pick your coding agent, then run its install command to add the Stride plugin:"
                )}
                <.agent_plugin_picker selected_agent={@selected_agent} />
              </.onboarding_step>

              <.onboarding_step number="3" title={gettext("Sign in to your account")}>
                {gettext("Use the button below to sign in with your new credentials.")}
              </.onboarding_step>

              <.onboarding_step number="4" title={gettext("Create your first board")}>
                {gettext("Boards are where your work lives — set one up for your team or project.")}
                <.link
                  href={~p"/resources/creating-your-first-board"}
                  target="_blank"
                  rel="noopener noreferrer"
                  style="color: var(--ink); text-decoration: underline;"
                >
                  {gettext("Guide: Creating your first board")}
                </.link>
              </.onboarding_step>

              <.onboarding_step number="5" title={gettext("Generate an API token")}>
                {gettext(
                  "On your board, open the Tokens tab to create one (available on AI-optimized boards). The token is shown only once — copy it and keep it secret."
                )}
                <.link
                  href={~p"/resources/api-authentication"}
                  target="_blank"
                  rel="noopener noreferrer"
                  style="color: var(--ink); text-decoration: underline;"
                >
                  {gettext("Guide: Configuring API authentication")}
                </.link>
              </.onboarding_step>

              <.onboarding_step number="6" title={gettext("Add your team")}>
                {gettext("Invite collaborators to your board and choose what they can do.")}
                <.link
                  href={~p"/resources/inviting-team-members"}
                  target="_blank"
                  rel="noopener noreferrer"
                  style="color: var(--ink); text-decoration: underline;"
                >
                  {gettext("Guide: Adding team members")}
                </.link>
              </.onboarding_step>
            </ol>
          </div>

          <div style="margin-top: 24px; width: 100%;">
            <.primary_full_button>
              <%!-- Match the button's label token (var(--surface)) so the link stays
                    legible on the inverted ink button in both light and dark. --%>
              <.link
                navigate={~p"/users/log-in"}
                style="color: var(--surface); text-decoration: none;"
              >
                {gettext("Sign in")} <span aria-hidden="true">→</span>
              </.link>
            </.primary_full_button>
          </div>
        <% else %>
          <h1 style="margin: 20px 0 0; font-size: 28px; font-weight: 600; letter-spacing: -0.025em; line-height: 1.15;">
            {gettext("Confirming your account…")}
          </h1>

          <p style="margin: 10px 0 0; font-size: 13.5px; color: var(--ink-3); max-width: 360px; text-wrap: pretty;">
            {gettext("Hold tight — this will only take a moment.")}
          </p>

          <div style="margin-top: 28px; padding: 12px 16px; background: var(--surface); border: 1px solid var(--line); border-radius: 8px; display: flex; align-items: center; gap: 12px; width: 100%;">
            <span style="width: 16px; height: 16px; border-radius: 50%; border: 2px solid var(--surface-sunken); border-top-color: var(--stride-orange); animation: authspin 0.8s linear infinite; flex-shrink: 0;"></span>
            <div style="flex: 1; text-align: left;">
              <div style="font-size: 12.5px; color: var(--ink); font-weight: 500;">
                {gettext("Verifying your confirmation link…")}
              </div>
              <div style="font-family: var(--font-mono); font-size: 10.5px; color: var(--ink-3); letter-spacing: -0.01em;">
                {gettext("you can sign in as soon as it's verified")}
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </.auth_frame>
    """
  end

  # The copy-paste prompt for the user's coding agent. The onboarding endpoint
  # returns the full setup instructions, so the prompt only needs to point the
  # agent at it and name the two files the setup produces.
  defp agent_onboarding_prompt do
    gettext(
      "Fetch %{url} and follow the instructions it returns to set up Stride in this project, creating the .stride_auth.md and .stride.md configuration files.",
      url: url(~p"/api/agent/onboarding")
    )
  end

  attr :number, :string, required: true
  attr :title, :string, required: true
  # `rich` steps render their body in a block-level <div> instead of the default
  # <p>, so a step can hold block content (e.g. the tab picker's buttons/panels)
  # without producing invalid HTML. Text-only steps keep the default <p>.
  attr :rich, :boolean, default: false
  slot :inner_block, required: true

  defp onboarding_step(assigns) do
    ~H"""
    <li style="display: flex; gap: 12px;">
      <span
        aria-hidden="true"
        style="width: 22px; height: 22px; border-radius: 50%; background: var(--surface-2); border: 1px solid var(--line); color: var(--ink-2); font-family: var(--font-mono); font-size: 11px; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0; margin-top: 1px;"
      >
        {@number}
      </span>
      <div style="flex: 1;">
        <div style="font-size: 13px; font-weight: 600; color: var(--ink);">
          {@title}
        </div>
        <div
          :if={@rich}
          style="margin: 2px 0 0; font-size: 12.5px; line-height: 1.5; color: var(--ink-3); text-wrap: pretty;"
        >
          {render_slot(@inner_block)}
        </div>
        <p
          :if={!@rich}
          style="margin: 2px 0 0; font-size: 12.5px; line-height: 1.5; color: var(--ink-3); text-wrap: pretty;"
        >
          {render_slot(@inner_block)}
        </p>
      </div>
    </li>
    """
  end

  # Segmented per-agent picker for the "Install the Stride plugin" step. The
  # agent list, install commands, and links come from KanbanWeb.OnboardingPlugins
  # (the single source of truth) — never inline the agent data here. Tab state
  # lives in the `selected_agent` assign and is driven by the "select_agent"
  # handle_event; only the selected agent's panel is rendered. Agent labels are
  # brand names rendered verbatim (not gettext'd); the per-plugin `note` field is
  # deliberately NOT rendered — the human-facing helper text is derived from the
  # structured flags with literal gettext strings so every string is extractable
  # and translated in all locales.
  attr :selected_agent, :string, required: true

  defp agent_plugin_picker(assigns) do
    assigns = assign(assigns, :agent, OnboardingPlugins.get(assigns.selected_agent))

    ~H"""
    <div style="margin-top: 8px;">
      <div
        role="tablist"
        aria-label={gettext("Coding agents")}
        style="display: flex; flex-wrap: wrap; gap: 6px;"
      >
        <button
          :for={agent <- OnboardingPlugins.agents()}
          type="button"
          role="tab"
          id={"agent-tab-#{agent.key}"}
          aria-selected={to_string(@selected_agent == agent.key)}
          {if @selected_agent == agent.key, do: %{"aria-controls" => "agent-panel-#{agent.key}"}, else: %{}}
          phx-click="select_agent"
          phx-value-agent={agent.key}
          style={tab_style(@selected_agent == agent.key)}
        >
          {agent.label}
        </button>
      </div>

      <div
        :if={@agent}
        role="tabpanel"
        id={"agent-panel-#{@agent.key}"}
        aria-labelledby={"agent-tab-#{@agent.key}"}
        style="margin-top: 12px; display: flex; flex-direction: column; gap: 12px;"
      >
        <div>
          <div style="font-family: var(--font-mono); font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3); margin-bottom: 4px;">
            {gettext("Workflow plugin")}
          </div>
          <span style="display: flex; gap: 8px; align-items: flex-start;">
            <code
              id={"workflow-command-#{@agent.key}"}
              style="flex: 1; padding: 6px 10px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-strong); color: var(--ink); font-family: var(--font-mono); font-size: 11px; line-height: 1.5; white-space: pre-wrap; word-break: break-word;"
            >{@agent.workflow_command}</code>
            <.copy_button id={"workflow-copy-#{@agent.key}"} value={@agent.workflow_command} />
          </span>
          <div style="margin-top: 4px; font-size: 11.5px; color: var(--ink-3); text-wrap: pretty;">
            <.link
              href={@agent.workflow_url}
              target="_blank"
              rel="noopener noreferrer"
              style="color: var(--ink); text-decoration: underline;"
            >
              {if @agent.uses_marketplace,
                do: gettext("View in the marketplace"),
                else: gettext("View the plugin repository")}
            </.link>
            <span>
              · {if @agent.uses_marketplace,
                do: gettext("Installs through the Stride marketplace."),
                else: gettext("Installs from its own repository — no marketplace.")}
            </span>
          </div>
        </div>

        <div :if={@agent.ideation_command}>
          <div style="font-family: var(--font-mono); font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3); margin-bottom: 4px;">
            {gettext("Ideation plugin (recommended)")}
          </div>
          <span style="display: flex; gap: 8px; align-items: flex-start;">
            <code
              id={"ideation-command-#{@agent.key}"}
              style="flex: 1; padding: 6px 10px; border-radius: 5px; background: var(--surface); border: 1px solid var(--line-strong); color: var(--ink); font-family: var(--font-mono); font-size: 11px; line-height: 1.5; white-space: pre-wrap; word-break: break-word;"
            >{@agent.ideation_command}</code>
            <.copy_button id={"ideation-copy-#{@agent.key}"} value={@agent.ideation_command} />
          </span>
          <div style="margin-top: 4px; font-size: 11.5px; color: var(--ink-3); text-wrap: pretty;">
            <.link
              href={@agent.ideation_url}
              target="_blank"
              rel="noopener noreferrer"
              style="color: var(--ink); text-decoration: underline;"
            >
              {gettext("View the ideation plugin")}
            </.link>
          </div>
        </div>

        <p
          :if={is_nil(@agent.ideation_command)}
          style="margin: 0; font-size: 11.5px; color: var(--ink-3);"
        >
          {gettext("No separate ideation plugin yet.")}
        </p>
      </div>
    </div>
    """
  end

  # Pill style for a picker tab; selected tabs invert to the ink/surface pair to
  # match the page's primary affordance. Only theme tokens (no literal colors) so
  # the picker stays correct in light and dark mode.
  defp tab_style(selected?) do
    base =
      "padding: 4px 11px; border-radius: 999px; font-size: 12px; font-weight: 500; " <>
        "font-family: inherit; cursor: pointer;"

    if selected? do
      base <> " background: var(--ink); color: var(--surface); border: 1px solid var(--ink);"
    else
      base <>
        " background: var(--surface-2); color: var(--ink-2); border: 1px solid var(--line);"
    end
  end

  # Client-side copy button reused across the picker's command blocks. Mirrors the
  # inline-onclick/data-* pattern used by Step 1 (no <script> tags): it reads the
  # value off a data-attribute, copies via a transient textarea + execCommand, and
  # briefly swaps its label to a confirmation.
  attr :id, :string, required: true
  attr :value, :string, required: true

  defp copy_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      data-token-value={@value}
      data-copy-text={gettext("Copy")}
      data-copied-text={"✓ " <> gettext("Copied!")}
      data-failed-msg={gettext("Failed to copy")}
      onclick="
        const text = this.getAttribute('data-token-value');
        const copiedText = this.getAttribute('data-copied-text');
        const copyText = this.getAttribute('data-copy-text');
        const failedMsg = this.getAttribute('data-failed-msg');
        const textarea = document.createElement('textarea');
        textarea.value = text;
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        try {
          document.execCommand('copy');
          this.innerHTML = copiedText;
          setTimeout(() => { this.innerHTML = copyText; }, 2000);
        } catch (err) {
          alert(failedMsg + ': ' + err.message);
        } finally {
          document.body.removeChild(textarea);
        }
      "
      style="padding: 6px 12px; border-radius: 5px; border: none; background: var(--ink); color: var(--surface); font-size: 12px; font-weight: 500; cursor: pointer; flex-shrink: 0;"
    >
      {gettext("Copy")}
    </button>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if connected?(socket) do
      send(self(), :confirm)
    end

    {:ok, assign(socket, token: token, confirmed: false, selected_agent: "claude_code")}
  end

  @impl true
  def handle_event("select_agent", %{"agent" => key}, socket) do
    # get/1 is nil-safe: an unknown/tampered key leaves the current selection.
    case OnboardingPlugins.get(key) do
      nil -> {:noreply, socket}
      agent -> {:noreply, assign(socket, :selected_agent, agent.key)}
    end
  end

  @impl true
  def handle_info(:confirm, socket) do
    case Accounts.confirm_user(socket.assigns.token) do
      {:ok, _user} ->
        {:noreply, assign(socket, confirmed: true)}

      {:error, :already_confirmed} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("This account has already been confirmed. You can log in."))
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, :invalid_token} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Confirmation link is invalid or has expired."))
         |> push_navigate(to: ~p"/users/log-in")}
    end
  end
end
