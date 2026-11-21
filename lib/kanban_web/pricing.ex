defmodule KanbanWeb.Pricing do
  @moduledoc """
  The one place the public plan prices are written down.

  The pricing page shows them through `price_label/1`, and its
  `SoftwareApplication` structured data (see `KanbanWeb.PageHTML`) turns
  `fixed_price_plans/0` into one schema.org `Offer` each, so the page and the
  block cannot disagree.

  The display currency is the single `@currency` attribute below. Switching it
  (the CAD or USD decision is still open) moves the page and the block
  together; `price_label/1` only has a clause for a currency it knows how to
  word, so a switch without a matching label raises instead of rendering a
  page whose text no longer matches its structured data.

  Plan names are English literals rather than gettext, because the structured
  data stays in one language whatever the page locale is.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @currency "CAD"

  @plans [
    %{key: :free, name: "Free", amount: 0, currency: @currency, unit: nil},
    %{
      key: :organization,
      name: "Organization",
      amount: 12,
      currency: @currency,
      unit: :user_month
    },
    # More than 250 users is priced on request, so it has no fixed amount and
    # is never offered in structured data.
    %{
      key: :organization_over_250,
      name: "Organization, more than 250 users",
      amount: nil,
      currency: nil,
      unit: nil
    }
  ]

  @type plan :: %{
          key: atom(),
          name: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil,
          unit: :user_month | nil
        }

  @doc """
  Every public plan, in the order the pricing page shows them.
  """
  @spec plans() :: [plan()]
  def plans, do: @plans

  @doc """
  The plan with the given key. Raises `ArgumentError` for an unknown key.
  """
  @spec plan!(atom()) :: plan()
  def plan!(key) do
    Enum.find(@plans, &(&1.key == key)) ||
      raise ArgumentError, "unknown plan #{inspect(key)}"
  end

  @doc """
  The plans that have a fixed price, which are the only ones offered in
  structured data. A plan priced on request (`amount: nil`) is left out.
  """
  @spec fixed_price_plans([plan()]) :: [plan()]
  def fixed_price_plans(plans \\ @plans) do
    Enum.filter(plans, &(is_integer(&1.amount) and is_binary(&1.currency)))
  end

  @doc """
  The translated price text the pricing page shows for a fixed-price plan,
  for example "$12 CAD" in English.
  """
  @spec price_label(plan()) :: String.t()
  def price_label(%{amount: amount, currency: "CAD"}) when is_integer(amount) do
    gettext("$%{amount} CAD", amount: amount)
  end
end
