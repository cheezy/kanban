defmodule KanbanWeb.TargetLive.Form do
  use KanbanWeb, :live_view

  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks.Task
  alias KanbanWeb.TargetGoalManageRow

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, member_goals: [], assignable_goals: [])
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Targets.get_owned_target(scope, id) do
      {:ok, target} -> apply_edit_action(socket, target)
      {:error, :not_found} -> target_not_authorized(socket)
    end
  end

  defp apply_action(socket, :new, _params) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(:page_title, "Stride")
    |> assign(:target, %DeliveryTarget{})
    |> assign(:owner_email, user.email)
    |> assign(:form, to_form(Targets.change_target(%DeliveryTarget{})))
  end

  @impl true
  def handle_event("validate", %{"delivery_target" => target_params}, socket) do
    changeset = Targets.change_target(socket.assigns.target, target_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  @impl true
  def handle_event("save", %{"delivery_target" => target_params}, socket) do
    save_target(socket, socket.assigns.live_action, target_params)
  end

  @impl true
  def handle_event("assign_goal", %{"goal_id" => goal_id}, socket) do
    scope = socket.assigns.current_scope
    target = socket.assigns.target

    case Targets.assign_goal(scope, %Task{id: String.to_integer(goal_id)}, target) do
      {:ok, _goal} -> {:noreply, assign_goal_lists(socket, target)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, gettext("Could not assign goal"))}
    end
  end

  @impl true
  def handle_event("unassign_goal", %{"goal_id" => goal_id}, socket) do
    scope = socket.assigns.current_scope
    target = socket.assigns.target

    case Targets.unassign_goal(scope, %Task{id: String.to_integer(goal_id)}) do
      {:ok, _goal} ->
        {:noreply, assign_goal_lists(socket, target)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not unassign goal"))}
    end
  end

  defp save_target(socket, :edit, target_params) do
    case Targets.update_target(
           socket.assigns.current_scope,
           socket.assigns.target,
           target_params
         ) do
      {:ok, _target} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Target updated successfully"))
         |> push_navigate(to: ~p"/boards")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :validate))}

      {:error, :not_authorized} ->
        {:noreply, target_not_authorized(socket)}
    end
  end

  defp save_target(socket, :new, target_params) do
    case Targets.create_target(socket.assigns.current_scope, target_params) do
      {:ok, target} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Target created successfully"))
         |> push_navigate(to: ~p"/targets/#{target}/edit")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :validate))}

      {:error, :not_authorized} ->
        {:noreply, target_not_authorized(socket)}
    end
  end

  defp apply_edit_action(socket, target) do
    socket
    |> assign(:page_title, "Stride")
    |> assign(:target, target)
    |> assign(:owner_email, target.owner.email)
    |> assign(:form, to_form(Targets.change_target(target)))
    |> assign_goal_lists(target)
  end

  defp assign_goal_lists(socket, target) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:member_goals, Targets.list_member_goal_details(scope, target))
    |> assign(:assignable_goals, Targets.list_assignable_goal_details(scope, target))
  end

  defp target_not_authorized(socket) do
    socket
    |> put_flash(:error, gettext("Only the target owner can edit this target"))
    |> push_navigate(to: ~p"/boards")
  end
end
