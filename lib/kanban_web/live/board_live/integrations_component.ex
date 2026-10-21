defmodule KanbanWeb.BoardLive.IntegrationsComponent do
  @moduledoc """
  The board's Integrations view (W2228): the owner lists, adds, edits,
  enables, disables and deletes webhook, Slack and Discord endpoints, sends a test
  event, rotates a generic endpoint's signing secret and reads each
  endpoint's recent deliveries. The markup is in
  `KanbanWeb.BoardLive.WebhookViews`.

  `KanbanWeb.BoardLive.Integrations` only lets the owner open the view.
  Every event that names an endpoint (edit, validate_edit, save_edit,
  toggle, rotate, delete, send_test, show_log) looks it up again with
  `Kanban.Webhooks.get_endpoint/3`, scoped to this board and the current
  user, so a forged id (another board's endpoint, or anything else) gets
  "Endpoint not found"; every write is owner-checked again by the context,
  and `create` relies on `Kanban.Webhooks.create_endpoint/4`'s own owner
  check. `validate`, `cancel_edit`, `hide_log` and `dismiss_secret` read and
  write no stored data.

  An edit (W2364) takes only the URL, when one was typed, and the events from
  its params: the kind and the enabled flag never change through it, and a
  blank URL keeps the stored one. The edit form never shows the stored URL,
  only its host, and the signing secret is kept.

  The signing secret is held in the `:revealed` assign, written only by the
  create and rotate handlers and cleared by dismiss or delete. `update/2`
  never sets it, and closing the modal unmounts the component, so the secret
  cannot be shown again. A Slack or Discord endpoint has no secret to
  show: their messages are not signed.

  A component's own flash never reaches the page, so flashes are sent to the
  parent LiveView, which applies them with `apply_parent_message/2`.

  Integrations are a paid feature. While paid plans are enforced, a free
  board's view (`:locked?`, computed once when the component mounts) shows the
  `KanbanWeb.LockedFeature` panel for `:integrations` and lists the existing
  endpoints read only with a Paused badge, keeping only Deliveries and Delete.
  The write events (create, save_edit, toggle, rotate, send_test) are refused
  first here (`Kanban.Plans.check_board/3`, surface `:live_view`) with a
  flash, and again by `Kanban.Webhooks` itself.
  """
  use KanbanWeb, :live_component

  alias Ecto.Changeset
  alias Kanban.Plans
  alias Kanban.Webhooks
  alias Kanban.Webhooks.Endpoint
  alias KanbanWeb.BoardLive.WebhookForm
  alias KanbanWeb.BoardLive.WebhookViews
  alias KanbanWeb.LockedFeature

  @log_size 20

  @impl true
  def update(%{board: _board, current_scope: _scope} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_defaults()
     |> assign_new(:form, fn %{form_rev: rev} -> new_form(rev) end)
     |> assign_new(:locked?, &locked?/1)
     |> reload()}
  end

  defp assign_defaults(socket) do
    Enum.reduce(
      [revealed: nil, log_endpoint_id: nil, editing: nil, deliveries: [], form_rev: 0],
      socket,
      fn {key, default}, acc -> assign_new(acc, key, fn -> default end) end
    )
  end

  defp locked?(%{board: board}), do: not Plans.board_unlocked?(board.id)

  @doc "Applies a flash this component sent to its parent LiveView."
  def apply_parent_message(socket, {:flash, kind, message}) when kind in [:info, :error] do
    Phoenix.LiveView.put_flash(socket, kind, message)
  end

  @impl true
  def handle_event("validate", %{"endpoint" => params}, socket) do
    form =
      %Endpoint{}
      |> Webhooks.change_endpoint(params)
      |> to_form(action: :validate, as: "endpoint", id: form_id(socket.assigns.form_rev))

    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("create", %{"endpoint" => params}, socket) do
    %{current_scope: scope, board: board} = socket.assigns

    with_plan(socket, fn ->
      scope
      |> Webhooks.create_endpoint(board, params)
      |> handle_create(socket)
    end)
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    with_plan(socket, fn ->
      with_endpoint(socket, id, fn endpoint ->
        form = endpoint |> Webhooks.change_endpoint() |> to_form(as: "endpoint_edit")
        {:noreply, assign(socket, :editing, %{endpoint_id: endpoint.id, form: form})}
      end)
    end)
  end

  @impl true
  def handle_event("validate_edit", %{"id" => id} = params, socket) do
    with_plan(socket, fn ->
      with_endpoint(socket, id, fn endpoint ->
        form =
          endpoint
          |> Webhooks.change_endpoint(edit_attrs(params))
          |> to_form(action: :validate, as: "endpoint_edit")

        {:noreply, assign(socket, :editing, %{endpoint_id: endpoint.id, form: form})}
      end)
    end)
  end

  @impl true
  def handle_event("save_edit", %{"id" => id} = params, socket) do
    with_plan(socket, fn ->
      with_endpoint(socket, id, fn endpoint ->
        socket.assigns.current_scope
        |> Webhooks.update_endpoint(endpoint, edit_attrs(params))
        |> handle_edit(endpoint, socket)
      end)
    end)
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    with_plan(socket, fn ->
      with_endpoint(socket, id, fn endpoint ->
        socket.assigns.current_scope
        |> Webhooks.update_endpoint(endpoint, %{"enabled" => not endpoint.enabled})
        |> handle_write(socket, toggled_message(endpoint))
      end)
    end)
  end

  @impl true
  def handle_event("rotate", %{"id" => id}, socket) do
    with_plan(socket, fn ->
      with_endpoint(socket, id, fn endpoint ->
        case Webhooks.rotate_secret(socket.assigns.current_scope, endpoint) do
          {:ok, {rotated, secret}} ->
            notify_parent({:flash, :info, gettext("Secret rotated")})
            {:noreply, socket |> reveal(rotated, secret) |> reload()}

          error ->
            handle_write(error, socket, nil)
        end
      end)
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
    with_plan(socket, fn ->
      with_endpoint(socket, id, fn endpoint ->
        socket.assigns.current_scope
        |> Webhooks.send_test_event(endpoint)
        |> handle_write(
          assign(socket, :log_endpoint_id, endpoint.id),
          gettext("Test event queued. Refresh the deliveries in a few seconds.")
        )
      end)
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

  # An event this panel does not define, or one without the params its clause
  # needs, can only be crafted. Ignore it rather than crash the board page.
  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp handle_create({:ok, {endpoint, secret}}, socket) do
    notify_parent({:flash, :info, gettext("Endpoint created")})
    {:noreply, socket |> reveal(endpoint, secret) |> reset_form() |> reload()}
  end

  defp handle_create({:error, %Changeset{} = changeset}, socket) do
    form =
      to_form(changeset, action: :insert, as: "endpoint", id: form_id(socket.assigns.form_rev))

    {:noreply, assign(socket, :form, form)}
  end

  defp handle_create({:error, :unauthorized}, socket), do: deny(socket)
  defp handle_create({:error, {:plan_required, :integrations}}, socket), do: refuse_locked(socket)

  defp handle_edit({:ok, _endpoint}, _endpoint_before, socket) do
    notify_parent({:flash, :info, gettext("Endpoint updated")})
    {:noreply, socket |> assign(:editing, nil) |> reload()}
  end

  # An :id error is the stale-update error: the endpoint was deleted between
  # the lookup and the write.
  defp handle_edit({:error, %Changeset{} = changeset}, endpoint, socket) do
    if Keyword.has_key?(changeset.errors, :id) do
      notify_parent({:flash, :error, gettext("Endpoint not found")})
      {:noreply, socket |> assign(:editing, nil) |> reload()}
    else
      form = to_form(changeset, action: :update, as: "endpoint_edit")
      {:noreply, assign(socket, :editing, %{endpoint_id: endpoint.id, form: form})}
    end
  end

  defp handle_edit({:error, :unauthorized}, _endpoint, socket), do: deny(socket)

  defp handle_edit({:error, {:plan_required, :integrations}}, _endpoint, socket),
    do: refuse_locked(socket)

  # Only the URL and the events can be edited. A blank URL keeps the stored
  # one, and events left out of the params (the form always sends them) keep
  # the stored events.
  defp edit_attrs(%{"endpoint_edit" => %{} = params}) do
    params
    |> Map.take(["event_types"])
    |> put_typed_url(params["url"])
  end

  defp edit_attrs(_params), do: %{}

  defp put_typed_url(attrs, url) when is_binary(url) do
    case String.trim(url) do
      "" -> attrs
      trimmed -> Map.put(attrs, "url", trimmed)
    end
  end

  defp put_typed_url(attrs, _url), do: attrs

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

  defp handle_write({:error, {:plan_required, :integrations}}, socket, _message),
    do: refuse_locked(socket)

  defp handle_write({:error, :disabled}, socket, _message) do
    notify_parent({:flash, :error, gettext("Enable the endpoint before sending a test event")})
    {:noreply, reload(socket)}
  end

  defp handle_write({:error, :creator_disabled}, socket, _message) do
    notify_parent(
      {:flash, :error,
       gettext(
         "The account that added this endpoint is disabled, so it sends nothing. Disable and enable it to take it over."
       )}
    )

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

  # The edit form renders inside its endpoint's row, so it goes away with a
  # deleted endpoint.
  defp open_edit_form(%{endpoint_id: id, form: form}, %Endpoint{id: id}), do: form
  defp open_edit_form(_editing, _endpoint), do: nil

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

  # A new rev gives the empty form new input ids as well as a new form id.
  # LiveView's patch reuses an element whose id is unchanged, and the old URL
  # input would bring its "already used" state into the empty form, so
  # changing the Kind would show "can't be blank" before anything was typed.
  defp reset_form(socket) do
    rev = socket.assigns.form_rev + 1

    socket
    |> assign(:form_rev, rev)
    |> assign(:form, new_form(rev))
  end

  defp new_form(rev),
    do: Webhooks.change_endpoint() |> to_form(as: "endpoint", id: form_id(rev))

  defp form_id(rev), do: "endpoint-#{rev}"

  # The write events on a free board under enforcement. Checked by board id on
  # every event, so a page that loaded while the board was paid is refused too.
  defp with_plan(socket, fun) do
    case Plans.check_board(socket.assigns.board.id, :integrations, surface: :live_view) do
      :ok -> fun.()
      {:error, {:plan_required, :integrations}} -> refuse_locked(socket)
    end
  end

  # Switches the view to its locked state, closing any edit form or secret.
  defp refuse_locked(socket) do
    notify_parent(
      {:flash, :error,
       gettext("Integrations are available to organizations. Nothing was changed.")}
    )

    {:noreply,
     socket
     |> assign(:locked?, true)
     |> assign(:editing, nil)
     |> assign(:revealed, nil)
     |> reload()}
  end

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
            "Each endpoint receives the task events you choose. Generic endpoints get a signed JSON POST; Slack and Discord endpoints get a message in a channel."
          )}
        </p>
        <LockedFeature.locked_feature
          :if={@locked?}
          feature={:integrations}
          variant={:panel}
          id="integrations-locked"
        />
        <WebhookViews.secret_reveal
          :if={@revealed && !@locked?}
          secret={@revealed.secret}
          myself={@myself}
        />
        <p
          :if={@endpoints == [] and !@locked?}
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
            edit_form={open_edit_form(@editing, endpoint)}
            paused?={@locked?}
          />
        </ul>
        <div :if={!@locked?} style="border-top: 1px solid var(--line); margin-top: 12px;">
          <WebhookForm.endpoint_form form={@form} rev={@form_rev} myself={@myself} />
        </div>
      </section>
    </div>
    """
  end
end
