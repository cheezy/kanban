defmodule KanbanWeb.SCIM.FallbackController do
  @moduledoc """
  Turns the errors of `Kanban.SCIM` into SCIM error responses (W2247).

  A refusal never names another Organization: a user who belongs to one, or
  whose account is disabled, gets the same generic conflict.
  """
  use KanbanWeb, :controller

  alias KanbanWeb.SCIM.Response

  @cannot_provision "The user cannot be provisioned in this Organization."

  def call(conn, {:error, reason}) do
    {status, scim_type, detail} = error(reason)
    Response.send_error(conn, status, scim_type, detail)
  end

  defp error(:not_found), do: {404, nil, "Resource not found."}

  defp error(:invalid_filter),
    do: {400, "invalidFilter", ~s(Only the filter form 'attribute eq "value"' is supported.)}

  defp error(:invalid_syntax), do: {400, "invalidSyntax", "The request body is not valid SCIM."}
  defp error(:invalid_path), do: {400, "invalidPath", "The operation path is not supported."}
  defp error(:invalid_value), do: {400, "invalidValue", "An attribute value is not valid."}

  defp error(:inactive_create),
    do: {400, "invalidValue", "A user cannot be created with active set to false."}

  defp error(:invalid_member),
    do: {400, "invalidValue", "Only members of the Organization can be added to a Group."}

  defp error(:domain_not_verified),
    do: {400, "invalidValue", "The userName's email domain is not verified by this Organization."}

  defp error(:mutability),
    do: {400, "mutability", "The attribute cannot be changed through SCIM."}

  defp error(:uniqueness),
    do: {409, "uniqueness", "A user with this userName already exists in this Organization."}

  defp error(:membership_conflict), do: {409, "uniqueness", @cannot_provision}
  defp error(:user_disabled), do: {409, "uniqueness", @cannot_provision}

  defp error(:last_org_admin),
    do:
      {409, nil,
       "The last org-admin of an Organization that has other members cannot be deprovisioned."}

  defp error(:unsupported),
    do: {403, nil, "Groups are created, renamed and archived in the Stride org console."}
end
