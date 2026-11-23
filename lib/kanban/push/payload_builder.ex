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

  A title, name or identifier is shown on one line, with control characters
  replaced by spaces and format characters removed (bidi overrides and
  isolates, zero-width spaces, direction marks), so it cannot add a line or
  read differently from what it is. What text needs is kept: the zero-width
  joiner and non-joiner, emoji tag sequences such as the England flag, and
  the visible marks some scripts write with a format character. Where a
  removal would fuse two characters into one, a space keeps them apart, and
  text with nothing visible left is left out, as an empty title is.

  Each piece is also capped by bytes, because a grapheme has none: one letter
  can carry thousands of combining marks, and APNs and FCM reject a payload
  over 4 KB outright. A title or target name keeps at most 160 graphemes and
  512 bytes, an identifier at most 64 graphemes and 128 bytes. The cut falls
  between whole graphemes, so it never splits a character or leaves a broken
  UTF-8 sequence; a grapheme bigger than the cap is dropped whole. Invalid
  UTF-8 is replaced with U+FFFD before anything else.

  When the recipient's Organization hides titles
  (`Kanban.Organizations.hide_titles?/1`), the title is left out and the text
  names only the kind and the identifier ("W2701 is ready for review"); a
  target's name is replaced too ("A target is at risk"). The target date
  stays.

  ## Locale

  The text is rendered in the device's locale, never the account's:
  `locale/1` maps the device's language tag through `Kanban.Locales.resolve/1`
  (D4): an exact translated locale, else the tag's base language (`"de-AT"`
  is `"de"`, `"pt-BR"` is `"pt"`, `"zh-Hant-TW"` is `"zh"`), else `"en"`
  (`"ko"`).

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
  alias Kanban.Locales
  alias Kanban.Notifications.Notification
  alias Kanban.Push.Payload

  # Both caps hold: a grapheme has no byte bound, and APNs and FCM reject a
  # payload over 4,096 bytes. With JSON escaping at most doubling a byte, the
  # identifier in the title plus a title or name stays well under it.
  @title_max 160
  @title_max_bytes 512
  @identifier_max 64
  @identifier_max_bytes 128

  # Format characters one_line/1 keeps: see the comment there.
  @kept_format "\\x{200C}\\x{200D}\\x{0600}-\\x{0605}\\x{06DD}\\x{070F}\\x{0890}\\x{0891}" <>
                 "\\x{08E2}\\x{110BD}\\x{110CD}\\x{13430}-\\x{1343F}"
  @emoji_tag_sequence "\\x{1F3F4}[\\x{E0020}-\\x{E007E}]+\\x{E007F}"
  @format_run ~r/#{@emoji_tag_sequence}|(?:(?![#{@kept_format}])\p{Cf})+/u
  @only_format_run ~r/\A(?:(?![#{@kept_format}])\p{Cf})+\z/u

  # What shows nothing on its own once one_line/1 has stripped: whitespace,
  # the kept joiners and hieroglyph controls, tag characters, variation
  # selectors and the other default-ignorable fillers.
  @not_visible ~r/[\s\x{200C}\x{200D}\x{13430}-\x{1343F}\x{034F}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{180B}-\x{180F}\x{3164}\x{FE00}-\x{FE0F}\x{FFA0}\x{E0000}-\x{E0FFF}]/u

  @summary_collapse_id "quiet_hours_summary"

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
  Builds the one summary push sent when a person's quiet hours end with
  `waiting` decisions still waiting (§7.9), in `locale`, such as "3 things
  waited overnight". It carries the count only, as the title and the badge,
  and opens Now; never a task title, an identifier or a name, so it reads the
  same whether or not the Organization hides titles.
  """
  @spec summary(pos_integer(), String.t()) :: Payload.t()
  def summary(waiting, locale) when is_integer(waiting) and waiting > 0 do
    title =
      Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
        ngettext("%{count} thing waited overnight", "%{count} things waited overnight", waiting)
      end)

    %Payload{
      collapse_id: @summary_collapse_id,
      title: title,
      badge: waiting,
      data: %{kind: @summary_collapse_id, route: "now"}
    }
  end

  @doc """
  The Gettext locale for `device`, from its language tag by
  `Kanban.Locales.resolve/1`: the exact translated locale, else the tag's
  base language, else `"en"`. A device with no locale is `"en"`.
  """
  @spec locale(Device.t()) :: String.t()
  def locale(%Device{locale: locale}), do: Locales.resolve(locale)

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
    do: capped(id, @identifier_max, @identifier_max_bytes) || fallback_identifier(n)

  defp identifier(_context, n), do: fallback_identifier(n)

  defp fallback_identifier(%Notification{task_id: id}) when is_integer(id), do: "##{id}"
  defp fallback_identifier(_n), do: "#"

  defp visible_title(%{hide_titles: true}), do: nil
  defp visible_title(%{subject: %{title: title}}) when is_binary(title), do: shown(title)
  defp visible_title(_context), do: nil

  defp target_name(%{hide_titles: true}), do: nil
  defp target_name(%{subject: %{name: name}}) when is_binary(name), do: shown(name)
  defp target_name(_context), do: nil

  defp shown(text), do: capped(text, @title_max, @title_max_bytes)

  defp capped(text, max_graphemes, max_bytes) do
    case one_line(text) do
      nil ->
        nil

      line ->
        line
        |> take_graphemes(max_graphemes, max_bytes)
        |> String.trim_trailing()
        |> visible_line()
    end
  end

  # The longest run of whole graphemes within both caps. Never binary_part:
  # a byte offset can fall inside a codepoint or a grapheme.
  defp take_graphemes(line, max_graphemes, max_bytes) do
    line
    |> Stream.unfold(&String.next_grapheme/1)
    |> Stream.take(max_graphemes)
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, size} ->
      size = size + byte_size(grapheme)
      if size > max_bytes, do: {:halt, {kept, size}}, else: {:cont, {[grapheme | kept], size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  # Free text never adds a line of its own: a line break or other control
  # character in a title could otherwise forge a count line in the body.
  # Format characters (\p{Cf}) are removed, so a bidi override or isolate
  # (U+202E, U+2066), a zero-width space (U+200B) or a direction mark
  # (U+200F) cannot make the lock-screen text read differently from the
  # title. Kept, because they reorder nothing and text needs them: the
  # zero-width non-joiner and joiner (emoji sequences, Persian), as in
  # Kanban.Attachments.Filename; the visible prepended concatenation marks
  # (Arabic number sign, Syriac abbreviation mark, Kaithi number sign);
  # Egyptian hieroglyph format controls; and a well-formed emoji tag
  # sequence, which is how the England, Scotland and Wales flags are spelled.
  # Where removing a run would regroup its neighbours (a skin tone onto the
  # emoji before it, two regional indicators into a flag, or a lone
  # indicator re-pairing the flag after it) a space keeps them apart. A title with nothing visible left is treated as
  # an empty one. Invalid UTF-8 would make the /u regexes raise, so it is
  # replaced with U+FFFD first.
  defp one_line(text) do
    text
    |> String.replace_invalid()
    |> strip_format()
    |> String.replace(~r/[\p{Cc}\p{Zl}\p{Zp}]+/u, " ")
    |> String.trim()
    |> visible_line()
  end

  defp strip_format(text) do
    @format_run
    |> Regex.split(text, include_captures: true)
    |> Enum.reduce({[], nil, false}, &join_piece/2)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp join_piece("", acc), do: acc

  defp join_piece(piece, {parts, last, seam?}) do
    cond do
      format_run?(piece) -> {parts, last, true}
      seam? and fuses?(last, piece) -> {[piece, " " | parts], last_grapheme(piece), false}
      true -> {[piece | parts], last_grapheme(piece), false}
    end
  end

  defp format_run?(piece), do: String.match?(piece, @only_format_run)

  defp fuses?(nil, _piece), do: false

  # Joining regroups the seam when the two sides no longer split back into
  # the same two characters: they fuse into one, or a regional indicator
  # pairs with the one after it instead of standing alone.
  defp fuses?(last, piece) do
    {first, _rest} = String.next_grapheme(piece)
    String.graphemes(last <> first) != [last, first]
  end

  defp last_grapheme(piece), do: piece |> String.graphemes() |> List.last()

  defp visible_line(line) do
    if String.replace(line, @not_visible, "") == "", do: nil, else: line
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
