defimpl FunWithFlags.Actor, for: Kanban.Accounts.User do
  @moduledoc """
  Lets `Kanban.FeatureFlags` gate a flag for one user (W2907).

  The id is `"user:<id>"` and nothing else: it is stored as plain text in
  `fun_with_flags_toggles`, so it must stay stable across email changes and
  must never carry personal data such as the email address.
  """

  def id(%Kanban.Accounts.User{id: id}) when is_integer(id), do: "user:#{id}"
end
