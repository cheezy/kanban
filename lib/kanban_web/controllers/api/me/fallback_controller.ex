defmodule KanbanWeb.API.Me.FallbackController do
  @moduledoc """
  The error responses of the person API (`/api/me/*`, W2748), in the shapes
  `priv/openapi/stride-api.json` documents for it:

    * a changeset is `422 {"errors": {field: [message]}}` (`ValidationError`),
      with the messages only, never the values sent;
    * `:not_found` is `404 {"error": "Not Found"}` (`Error`), whether the
      record is missing or belongs to someone else;
    * `:revoked`, a device revoked while its request was in flight, is the
      `401 {"error": "Invalid access token"}` that
      `KanbanWeb.Plugs.AuthenticateDeviceToken` answers for a revoked device,
      so the app handles both the same way;
    * `{:plan_required, feature}`, a route the person's plan or the board's
      does not unlock (design §10), is `403 {"error": "plan_required",
      "feature": feature, "message": message}` (`PlanRequired`), the shape
      the agent API answers for a locked feature, so the app can show its
      locked panel without matching message text.

  The agent API's `KanbanWeb.API.FallbackController` attaches task
  documentation links and a different 404 body, which is why the person API
  has its own.
  """
  use KanbanWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &interpolate/1)})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not Found"})
  end

  def call(conn, {:error, {:plan_required, feature}}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "plan_required",
      feature: to_string(feature),
      message: plan_message(feature)
    })
  end

  def call(conn, {:error, :revoked}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Invalid access token"})
  end

  defp plan_message(:mobile_app), do: "The Stride app is available to boards in an Organization."
  defp plan_message(_feature), do: "This feature is available to boards in an Organization."

  defp interpolate({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", stringify(value))
    end)
  end

  defp stringify(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp stringify(value), do: inspect(value)
end
