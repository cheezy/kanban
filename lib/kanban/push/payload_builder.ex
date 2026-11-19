defmodule Kanban.Push.PayloadBuilder do
  @moduledoc """
  Builds the `Kanban.Push.Payload` for one notification on one device
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.8, §9.4, §6.20).

  ## What a push may carry (§9.4)

  Only the event kind, the identifier, the task or goal title, a target's
  name and date, and counts (checks passed and failed, tasks held up). It
  never reads the notification's `body` (review notes, an unclaim reason),
  a decision's `reason` or `first_failed_note`, hook output, code or comment
  text, and it never names the person who acted.

  When the recipient's Organization hides titles
  (`Kanban.Organizations.hide_titles?/1`), the title is left out and the text
  names only the kind and the identifier ("W2701 is ready for review"); a
  target's name is replaced too ("A target is at risk"). The target date
  stays.

  ## Locale

  The text is rendered in the device's locale, never the account's:
  `locale/1` takes the primary subtag of the device's locale (`"ja-JP"` is
  `"ja"`) and falls back to `"en"` for one Stride is not translated into.

  ## Collapse id, route and data

    * the collapse id is the decision id for the four decision events, such
      as `"review:task:4812"`, and `"event_type:subject_id"` for an update,
      such as `"goal_completed:977"` (the target id for
      `target_status_changed`, read from its `/targets/:id` path);
    * the badge is the person's decisions count, given by the caller;
    * `data` carries `kind` (the event type), `route` (where a tap opens,
      §6.20), `notification_id`, and the ids the route needs: `board_id`,
      `task_id`, `decision_id`, `target_id` or `comment_id`. It carries no
      title or name.
  """

  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Devices.Device
  alias Kanban.Notifications.Notification
  alias Kanban.Push.Payload

  @default_locale "en"
  @title_max 160

  @decision_prefixes %{
    review_requested: "review:task",
    task_unclaimed: "released:task",
    claim_expired: "claim_expired:task",
    after_goal_failed: "hook_failed:goal"
  }

  @routes %{
    review_requested: "review",
    task_unclaimed: "now",
    claim_expired: "now",
    after_goal_failed: "now",
    task_reviewed: "task",
    goal_completed: "goal",
    target_status_changed: "target",
    mentioned: "comments"
  }

  @typedoc """
  What the payload is built from, besides the notification:

    * `:locale` - a Gettext locale, from `locale/1`
    * `:hide_titles` - whether the Organization hides titles
    * `:badge` - the decisions count
    * `:subject` - `%{identifier:, title:}` for a task or goal event, and
      `%{name:}` for a target
    * `:decision` - the open decision item for a decision event
      (`Kanban.Decisions.item/0`), else `nil`
  """
  @type context :: %{
          locale: String.t(),
          hide_titles: boolean(),
          badge: non_neg_integer() | nil,
          subject: map(),
          decision: map() | nil
        }

  @doc "The event types that are decisions, whose push needs an open decision."
  @spec decision_events() :: [atom()]
  def decision_events, do: Map.keys(@decision_prefixes)

  @doc """
  Builds the payload for `notification` with `context` (see `t:context/0`).
  """
  @spec build(Notification.t(), context()) :: Payload.t()
  def build(%Notification{} = notification, context) do
    {title, body} =
      Gettext.with_locale(KanbanWeb.Gettext, context.locale, fn ->
        {title(notification, context), body(notification, context)}
      end)

    %Payload{
      collapse_id: collapse_id(notification),
      title: title,
      body: body,
      badge: context.badge,
      data: data(notification)
    }
  end

  @doc """
  The Gettext locale for `device`: the primary subtag of its locale when
  Stride is translated into it, else `"en"`.
  """
  @spec locale(Device.t()) :: String.t()
  def locale(%Device{locale: locale}) when is_binary(locale) do
    primary =
      locale
      |> String.split(["-", "_"], parts: 2)
      |> hd()
      |> String.downcase()

    if primary in Gettext.known_locales(KanbanWeb.Gettext), do: primary, else: @default_locale
  end

  def locale(%Device{}), do: @default_locale

  @doc """
  The decision id a decision event's push is about, as `Kanban.Decisions`
  names it, or `nil` for any other event.
  """
  @spec decision_id(Notification.t()) :: String.t() | nil
  def decision_id(%Notification{event_type: type, task_id: task_id}) when is_integer(task_id) do
    case Map.fetch(@decision_prefixes, type) do
      {:ok, prefix} -> "#{prefix}:#{task_id}"
      :error -> nil
    end
  end

  def decision_id(%Notification{}), do: nil

  @doc """
  The collapse id: the decision id for a decision event, else
  `"event_type:subject_id"`. A notification whose subject id cannot be found
  falls back to its own id, so it still collapses with itself.
  """
  @spec collapse_id(Notification.t()) :: String.t()
  def collapse_id(%Notification{} = notification) do
    decision_id(notification) ||
      "#{notification.event_type}:#{subject_id(notification) || "n#{notification.id}"}"
  end

  @doc "Where a tap on the event's push opens (§6.20), or `nil` for one that never pushes."
  @spec route(atom()) :: String.t() | nil
  def route(event_type), do: Map.get(@routes, event_type)

  @doc """
  The target id of a `target_status_changed` notification, read from its
  `/targets/:id` path, or `nil`.
  """
  @spec target_id(Notification.t()) :: pos_integer() | nil
  def target_id(%Notification{url_path: "/targets/" <> rest}) do
    case Integer.parse(rest) do
      {id, ""} when id > 0 -> id
      _other -> nil
    end
  end

  def target_id(%Notification{}), do: nil

  defp subject_id(%Notification{event_type: :target_status_changed} = n), do: target_id(n)
  defp subject_id(%Notification{task_id: task_id}), do: task_id

  # -- title -------------------------------------------------------------------

  defp title(%Notification{event_type: :target_status_changed} = n, context),
    do: target_title(n.metadata["status"], target_name(context))

  defp title(%Notification{event_type: type} = n, context),
    do: task_title(type, n, identifier(context, n))

  defp task_title(:review_requested, _n, id),
    do: gettext("%{identifier} is ready for review", identifier: id)

  defp task_title(:task_unclaimed, _n, id),
    do: gettext("%{identifier} was released", identifier: id)

  defp task_title(:claim_expired, _n, id),
    do: gettext("The claim on %{identifier} expired", identifier: id)

  defp task_title(:after_goal_failed, _n, id),
    do: gettext("The after-goal hook failed on %{identifier}", identifier: id)

  defp task_title(:goal_completed, _n, id),
    do: gettext("%{identifier} is complete", identifier: id)

  defp task_title(:mentioned, _n, id),
    do: gettext("You were mentioned on %{identifier}", identifier: id)

  defp task_title(:task_reviewed, n, id), do: reviewed_title(n.metadata["outcome"], id)

  defp reviewed_title("approved", id), do: gettext("%{identifier} was approved", identifier: id)

  defp reviewed_title("changes_requested", id),
    do: gettext("Changes requested on %{identifier}", identifier: id)

  defp reviewed_title(_outcome, id), do: gettext("%{identifier} was reviewed", identifier: id)

  defp target_title("at_risk", nil), do: gettext("A target is at risk")
  defp target_title("at_risk", name), do: gettext("%{name} is at risk", name: name)
  defp target_title("missed", nil), do: gettext("A target missed its date")
  defp target_title("missed", name), do: gettext("%{name} missed its date", name: name)
  defp target_title(_status, _name), do: gettext("Target status changed")

  # -- body --------------------------------------------------------------------

  defp body(%Notification{event_type: :target_status_changed} = n, _context) do
    case n.metadata["target_date"] do
      date when is_binary(date) and date != "" -> gettext("Target date %{date}", date: date)
      _missing -> nil
    end
  end

  defp body(%Notification{}, context) do
    [visible_title(context) | decision_lines(context.decision)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp decision_lines(nil), do: []

  defp decision_lines(item) do
    verdicts = get_in(item, [:details, :verdicts]) || []

    [
      count_line(verdicts, "passed", fn n ->
        ngettext("%{count} check passed", "%{count} checks passed", n)
      end),
      count_line(verdicts, "failed", fn n ->
        ngettext("%{count} check failed", "%{count} checks failed", n)
      end),
      holds_up_line(item[:holds_up])
    ]
  end

  defp count_line(verdicts, status, render) do
    case Enum.count(verdicts, &(verdict_status(&1) == status)) do
      0 -> nil
      n -> render.(n)
    end
  end

  defp verdict_status(%{status: status}), do: status
  defp verdict_status(_verdict), do: nil

  defp holds_up_line(n) when is_integer(n) and n > 0,
    do: ngettext("Holds up %{count} task", "Holds up %{count} tasks", n)

  defp holds_up_line(_n), do: nil

  # -- subject -----------------------------------------------------------------

  # A task without an identifier is named by its id, which reads the same in
  # every locale's sentence.
  defp identifier(%{subject: %{identifier: id}}, n) when is_binary(id),
    do: one_line(id) || fallback_identifier(n)

  defp identifier(_context, n), do: fallback_identifier(n)

  defp fallback_identifier(%Notification{task_id: id}) when is_integer(id), do: "##{id}"
  defp fallback_identifier(_n), do: "#"

  defp visible_title(%{hide_titles: true}), do: nil
  defp visible_title(%{subject: %{title: title}}) when is_binary(title), do: shown(title)
  defp visible_title(_context), do: nil

  defp target_name(%{hide_titles: true}), do: nil
  defp target_name(%{subject: %{name: name}}) when is_binary(name), do: shown(name)
  defp target_name(_context), do: nil

  defp shown(text) do
    case one_line(text) do
      nil -> nil
      line -> String.slice(line, 0, @title_max)
    end
  end

  # Free text never adds a line of its own: a line break or other control
  # character in a title could otherwise forge a count line in the body.
  defp one_line(text) do
    text
    |> String.replace(~r/[\p{Cc}\p{Zl}\p{Zp}]+/u, " ")
    |> String.trim()
    |> case do
      "" -> nil
      line -> line
    end
  end

  # -- data --------------------------------------------------------------------

  defp data(%Notification{event_type: type} = n) do
    %{
      kind: Atom.to_string(type),
      route: route(type),
      notification_id: n.id,
      board_id: n.board_id,
      task_id: n.task_id,
      decision_id: decision_id(n)
    }
    |> Map.merge(event_ids(n))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp event_ids(%Notification{event_type: :target_status_changed} = n),
    do: %{target_id: target_id(n)}

  defp event_ids(%Notification{event_type: :mentioned, metadata: metadata}),
    do: %{comment_id: (metadata || %{})["comment_id"]}

  defp event_ids(_n), do: %{}
end
