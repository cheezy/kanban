defmodule Kanban.Push.Payload do
  @moduledoc """
  What one push carries, before a platform adapter turns it into an APNs or
  FCM notification (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.8).

    * `:collapse_id` (required) — the key a newer push replaces an older one
      by: the decision id for a decision event, such as `"review:task:4812"`,
      or `"event_type:subject_id"` for an update, such as
      `"goal_completed:977"`. APNs sends it as `apns-collapse-id`; FCM as the
      Android notification `tag` and the `collapse_key`.
    * `:title` and `:body` — the visible text. With neither, the push is a
      silent, data-only one that only refreshes the app and its widget.
    * `:badge` — the iOS badge, the person's decisions count.
    * `:data` — extra key/value pairs for the app. Keys and values are sent
      as strings.

  The §9.4 content rules (kind, identifier, title, counts and agent names
  only; never free text, review notes, hook output, code or comments) are the
  caller's to keep: this struct carries whatever it is given.
  `Kanban.Push.PayloadBuilder` builds it for a notification's push.
  """

  @enforce_keys [:collapse_id]
  defstruct [:collapse_id, :title, :body, :badge, data: %{}]

  @type t :: %__MODULE__{
          collapse_id: String.t(),
          title: String.t() | nil,
          body: String.t() | nil,
          badge: non_neg_integer() | nil,
          data: map()
        }

  @doc """
  The payload's `data` with every key and value turned into a string, plus
  `"collapse_id"`, so the app can read the collapse key from a data-only push.
  """
  @spec string_data(t()) :: %{String.t() => String.t()}
  def string_data(%__MODULE__{collapse_id: collapse_id, data: data}) do
    data
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Map.put("collapse_id", collapse_id)
  end

  @doc "True when the payload has a visible title or body."
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{title: title, body: body}), do: present?(title) or present?(body)

  defp present?(value), do: is_binary(value) and value != ""
end
