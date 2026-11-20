defmodule KanbanWeb.SeoOnMountTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.SeoOnMount
  alias Phoenix.LiveView.Socket

  defp socket, do: %Socket{assigns: %{__changed__: %{}}}

  describe "on_mount(:noindex, ...)" do
    test "assigns noindex: true and continues" do
      assert {:cont, socket} = SeoOnMount.on_mount(:noindex, %{}, %{}, socket())
      assert socket.assigns.noindex == true
    end

    test "ignores params and session" do
      assert {:cont, socket} =
               SeoOnMount.on_mount(:noindex, :not_mounted_at_router, %{"x" => 1}, socket())

      assert socket.assigns.noindex == true
    end
  end
end
