defmodule KanbanWeb.BoardLive.IntegrationsComponent do
  @moduledoc """
  The board's Integrations view (W2228): the owner lists, adds, enables,
  disables and deletes webhook and Slack endpoints, sends a test event,
  rotates a generic endpoint's signing secret and reads each endpoint's
  recent deliveries. The markup is in `KanbanWeb.BoardLive.WebhookViews`.

  `KanbanWeb.BoardLive.Integrations` only lets the owner open the view.
  Every event that names an endpoint (toggle, rotate, delete, send_test,
  show_log) looks it up again with `Kanban.Webhooks.get_endpoint/3`, scoped
  to this board and the current user, so a forged id (another board's
  endpoint, or anything else) gets "Endpoint not found"; every write is
  owner-checked again by the context, and `create` relies on
  `Kanban.Webhooks.create_endpoint/4`'s own owner check. `validate`,
  `hide_log` and `dismiss_secret` read and write no stored data.

  The signing secret is held in the `:revealed` assign, written only by the
  create and rotate handlers and cleared by dismiss or delete. `update/2`
  never sets it, and closing the modal unmounts the component, so the secret
  cannot be shown again. A Slack endpoint's secret is never shown: Slack
  messages are not signed.

  A component's own flash never reaches the page, so flashes are sent to the
  parent LiveView, which applies them with `apply_parent_message/2`.
  """
  use KanbanWeb, :live_component

  alias Ecto.Changeset
  alias Kanban.Webhooks
  alias Kanban.Webhooks.Endpoint
  alias KanbanWeb.BoardLive.WebhookForm
  alias KanbanWeb.BoardLive.WebhookViews

  @log_size 20

  @impl true
  def update(%{board: _board, current_scope: _scope} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:revealed, fn -> nil end)
     |> assign_new(:log_endpoint_id, fn -> nil end)
     |> assign_new(:deliveries, fn -> [] end)
     |> assign_new(:form_rev, fn -> 0 end)
     |> assign_new(:form, &new_form/0)
     |> reload()}
  end

  @doc "Applies a flash this component sent to its parent LiveView."
  def apply_parent_message(socket, {:flash, kind, message}) when kind in [:info, :error] do
    Phoenix.LiveView.put_flash(socket, kind, message)
  end

  @impl true
  def handle_event("validate", %{"endpoint" => params}, socket) do
    form =
      %Endpoint{}
      |> Webhooks.change_endpoint(params)
      |> to_form(action: :validate, as: "endpoint")

    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("create", %{"endpoint" => params}, socket) do
    %{current_scope: scope, board: board} = socket.assigns

    scope
    |> Webhooks.create_endpoint(board, params)
    |> handle_create(socket)
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn endpoint ->
      socket.assigns.current_scope
      |> Webhooks.update_endpoint(endpoint, %{"enabled" => not endpoint.enabled})
      |> handle_write(socket, toggled_message(endpoint))
    end)
  end

  @impl true
  def handle_event("rotate", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn endpoint ->
      case Webhooks.rotate_secret(socket.assigns.current_scope, endpoint) do
        {:ok, {rotated, secret}} ->
          notify_parent({:flash, :info, gettext("Secret rotated")})
          {:noreply, socket |> reveal(rotated, secret) |> reload()}

        error ->
          handle_write(error, socket, nil)
      end
    end)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn endpoint ->
      socket.assigns.current_scope
      |> Webhooks.delete_endpoint(endpoint)
      |> handle_write(forget(socket, endpoint.id), gettext("Endpoint deleted"))
    end)
  end

  @impl true
  def handle_event("send_test", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn endpoint ->
      socket.assigns.current_scope
      |> Webhooks.send_test_event(endpoint)
      |> handle_write(
        assign(socket, :log_endpoint_id, endpoint.id),
        gettext("Test event queued. Refresh the deliveries in a few seconds.")
      )
    end)
  end

  @impl true
  def handle_event("show_log", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn endpoint ->
      {:noreply, socket |> assign(:log_endpoint_id, endpoint.id) |> assign_log()}
    end)
  end

  @impl true
  def handle_event("hide_log", _params, socket) do
    {:noreply, socket |> assign(:log_endpoint_id, nil) |> assign(:deliveries, [])}
  end

  @impl true
  def handle_event("dismiss_secret", _params, socket) do
    {:noreply, assign(socket, :revealed, nil)}
  end

  defp handle_create({:ok, {endpoint, secret}}, socket) do
    notify_parent({:flash, :info, gettext("Endpoint created")})
    {:noreply, socket |> reveal(endpoint, secret) |> reset_form() |> reload()}
  end

  defp handle_create({:error, %Changeset{} = changeset}, socket) do
    {:noreply, assign(socket, :form, to_form(changeset, action: :insert, as: "endpoint"))}
  end

  defp handle_create({:error, :unauthorized}, socket), do: deny(socket)

  # The per-event ownership check: the id is looked up on this board for the
  # current user, never trusted.
  defp with_endpoint(socket, id, fun) do
    %{current_scope: scope, board: board} = socket.assigns

    case Webhooks.get_endpoint(scope, board, id) do
      {:ok, endpoint} ->
        fun.(endpoint)

      {:error, :not_found} ->
        notify_parent({:flash, :error, gettext("Endpoint not found")})
        {:noreply, reload(socket)}
    end
  end

  defp handle_write({:ok, _result}, socket, message) do
    if message, do: notify_parent({:flash, :info, message})
    {:noreply, reload(socket)}
  end

  defp handle_write({:error, :unauthorized}, socket, _message), do: deny(socket)

  defp handle_write({:error, :disabled}, socket, _message) do
    notify_parent({:flash, :error, gettext("Enable the endpoint before sending a test event")})
    {:noreply, reload(socket)}
  end

  defp handle_write({:error, _changeset}, socket, _message) do
    notify_parent(
      {:flash, :error, gettext("Could not update the endpoint. Reload and try again.")}
    )

    {:noreply, reload(socket)}
  end

  defp toggled_message(%Endpoint{enabled: true}), do: gettext("Endpoint disabled")
  defp toggled_message(%Endpoint{}), do: gettext("Endpoint enabled")

  # Slack messages are not signed, so a Slack endpoint's secret is never shown.
  defp reveal(socket, %Endpoint{kind: :generic, id: id}, secret),
    do: assign(socket, :revealed, %{endpoint_id: id, secret: secret})

  defp reveal(socket, _endpoint, _secret), do: socket

  defp forget(socket, endpoint_id) do
    socket
    |> update(:revealed, &if(&1 && &1.endpoint_id == endpoint_id, do: nil, else: &1))
    |> update(:log_endpoint_id, &if(&1 == endpoint_id, do: nil, else: &1))
  end

  defp reload(socket) do
    %{current_scope: scope, board: board} = socket.assigns

    socket
    |> assign(:endpoints, Webhooks.list_endpoints(scope, board))
    |> assign_log()
  end

  # The open log follows the endpoint list: a deleted endpoint closes it.
  defp assign_log(%{assigns: %{log_endpoint_id: id, endpoints: endpoints}} = socket) do
    case Enum.find(endpoints, &(&1.id == id)) do
      nil ->
        socket |> assign(:log_endpoint_id, nil) |> assign(:deliveries, [])

      endpoint ->
        assign(
          socket,
          :deliveries,
          Webhooks.list_deliveries(socket.assigns.current_scope, endpoint, @log_size)
        )
    end
  end

  defp reset_form(socket) do
    socket
    |> assign(:form, new_form())
    |> update(:form_rev, &(&1 + 1))
  end

  defp new_form, do: Webhooks.change_endpoint() |> to_form(as: "endpoint")

  defp deny(socket) do
    notify_parent({:flash, :error, gettext("Only the board owner can manage integrations")})
    {:noreply, socket}
  end

  defp notify_parent(message), do: send(self(), {__MODULE__, message})

  @impl true
  def render(assigns) do
    ~H"""
    <div class="stride-screen" id={"board-integrations-#{@board.id}"} data-integrations>
      <section
        id="webhooks-section"
        style={[
          "background: var(--surface); border: 1px solid var(--line);",
          "border-radius: 10px; padding: 14px 16px; margin-bottom: 14px;"
        ]}
      >
        <h3 style="margin: 0; font-size: 13px; font-weight: 600; color: var(--ink); letter-spacing: -0.015em;">
          {gettext("Webhooks")}
        </h3>
        <p style="margin: 4px 0 12px; font-size: 11.5px; color: var(--ink-3); line-height: 1.5;">
          {gettext(
            "Each endpoint receives the task events you choose. Generic endpoints get a signed JSON POST; Slack endpoints get a message in a channel."
          )}
        </p>
        <WebhookViews.secret_reveal :if={@revealed} secret={@revealed.secret} myself={@myself} />
        <p
          :if={@endpoints == []}
          data-webhooks-empty
          style="margin: 0 0 4px; font-size: 12px; color: var(--ink-3);"
        >
          {gettext("No endpoints yet. Add one below to send task events to another service.")}
        </p>
        <ul :if={@endpoints != []} id="webhook-endpoints" style="margin: 0; padding: 0;">
          <WebhookViews.endpoint_row
            :for={endpoint <- @endpoints}
            endpoint={endpoint}
            myself={@myself}
            log_open?={@log_endpoint_id == endpoint.id}
            deliveries={if @log_endpoint_id == endpoint.id, do: @deliveries, else: []}
          />
        </ul>
        <div style="border-top: 1px solid var(--line); margin-top: 12px;">
          <WebhookForm.endpoint_form form={@form} rev={@form_rev} myself={@myself} />
        </div>
      </section>
    </div>
    """
  end
end
