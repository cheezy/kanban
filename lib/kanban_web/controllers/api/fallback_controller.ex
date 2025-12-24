defmodule KanbanWeb.API.FallbackController do
  use KanbanWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: KanbanWeb.API.TaskJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: KanbanWeb.API.ErrorJSON)
    |> render(:"404")
  end
end
