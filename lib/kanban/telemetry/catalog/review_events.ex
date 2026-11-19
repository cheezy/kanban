defmodule Kanban.Telemetry.Catalog.ReviewEvents do
  @moduledoc """
  The app approval events in `Kanban.Telemetry.Catalog`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.5, §16), both emitted by
  `Kanban.Reviews.Approval`.

  `phone_approval_refused` is emitted when the large-change guard refuses an
  approval challenge or an approval made on a phone, with the change size and
  the task and board ids, so a refused review can be followed to where it was
  finished. `approval_signature_rejected` is emitted when an app approval is
  refused at its signature check, with the device class and the fixed reason
  (`missing`, `invalid`, `expired` or `reused`); the
  `:approval_signature_rejected` audit row records the same. Neither carries
  the nonce, the signature or a key.

  Neither is persisted: a signed-in device can cause either at will.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :review, :phone_approval_refused],
      kind: :event,
      domain: :review,
      measurements: [:count, :files, :changed_lines],
      metadata: [:task_id, :board_id],
      description:
        "The large-change guard refused an approval made on a phone: the change has more than 10 files, more than 500 changed lines, or a truncated diff. files and changed_lines are its size.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :review, :approval_signature_rejected],
      kind: :event,
      domain: :review,
      measurements: [:count],
      metadata: [:task_id, :board_id, :device_class, :reason],
      description:
        "An app approval was refused at its signature check. reason is :missing, :invalid, :expired or :reused; device_class is phone or tablet. Never the nonce or the signature.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:reason]
    }
  ]

  @doc """
  Returns the app approval entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
