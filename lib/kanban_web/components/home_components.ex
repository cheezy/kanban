defmodule KanbanWeb.HomeComponents do
  use Phoenix.Component

  attr :class, :string, default: ""
  slot :inner_block, required: true

  def hero_badge(assigns) do
    ~H"""
    <div class={[
      "inline-flex items-center px-4 py-2 bg-blue-100 text-blue-700",
      "rounded-full text-sm font-medium",
      @class
    ]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :class, :string, default: ""
  slot :inner_block, required: true

  def hero_title(assigns) do
    ~H"""
    <h1 class={[
      "text-4xl sm:text-5xl lg:text-6xl font-bold text-gray-900 leading-tight",
      @class
    ]}>
      <%= render_slot(@inner_block) %>
    </h1>
    """
  end

  attr :class, :string, default: ""
  slot :inner_block, required: true

  def hero_title_gradient(assigns) do
    ~H"""
    <span class={[
      "block text-transparent bg-clip-text bg-gradient-to-r from-blue-600 to-blue-800",
      @class
    ]}>
      <%= render_slot(@inner_block) %>
    </span>
    """
  end

  attr :href, :string, required: true
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def btn_primary(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "inline-flex items-center justify-center px-8 py-4 text-base font-semibold",
        "text-white bg-gradient-to-r from-blue-600 to-blue-700",
        "hover:from-blue-700 hover:to-blue-800 rounded-lg shadow-lg hover:shadow-xl",
        "transition-all transform hover:-translate-y-0.5",
        @class
      ]}
    >
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  attr :href, :string, required: true
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def btn_outline(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "inline-flex items-center justify-center px-8 py-4 text-base font-semibold",
        "text-gray-700 bg-white hover:bg-gray-50 border-2 border-gray-300",
        "rounded-lg shadow-sm hover:shadow-md transition-all",
        @class
      ]}
    >
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  attr :title, :string, required: true
  attr :todo_label, :string, required: true
  attr :progress_label, :string, required: true
  attr :done_label, :string, required: true

  def mock_board(assigns) do
    ~H"""
    <div class="relative bg-white rounded-2xl shadow-2xl p-6 space-y-4">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-lg font-bold text-gray-900">{@title}</h3>
        <div class="flex gap-1">
          <div class="w-3 h-3 bg-red-400 rounded-full"></div>
          <div class="w-3 h-3 bg-yellow-400 rounded-full"></div>
          <div class="w-3 h-3 bg-green-400 rounded-full"></div>
        </div>
      </div>
      <div class="grid grid-cols-3 gap-3">
        <.mock_column header={@todo_label} color="gray">
          <.mock_card>
            <div class="h-2 bg-blue-500 rounded w-3/4 mb-2"></div>
            <div class="h-2 bg-gray-200 rounded w-full"></div>
          </.mock_card>
          <.mock_card>
            <div class="h-2 bg-blue-500 rounded w-1/2 mb-2"></div>
            <div class="h-2 bg-gray-200 rounded w-full"></div>
          </.mock_card>
        </.mock_column>

        <.mock_column header={@progress_label} color="blue">
          <.mock_card color="blue">
            <div class="h-2 bg-orange-500 rounded w-2/3 mb-2"></div>
            <div class="h-2 bg-gray-200 rounded w-full"></div>
          </.mock_card>
        </.mock_column>

        <.mock_column header={@done_label} color="green">
          <.mock_card color="green">
            <div class="h-2 bg-green-500 rounded w-full mb-2"></div>
            <div class="h-2 bg-gray-200 rounded w-3/4"></div>
          </.mock_card>
          <.mock_card color="green">
            <div class="h-2 bg-green-500 rounded w-5/6 mb-2"></div>
            <div class="h-2 bg-gray-200 rounded w-2/3"></div>
          </.mock_card>
        </.mock_column>
      </div>
    </div>
    """
  end

  attr :header, :string, required: true
  attr :color, :string, default: "gray"
  slot :inner_block, required: true

  defp mock_column(assigns) do
    ~H"""
    <div class={[
      "rounded-lg p-3 space-y-2",
      @color == "gray" && "bg-gray-50",
      @color == "blue" && "bg-blue-50",
      @color == "green" && "bg-green-50"
    ]}>
      <div class={[
        "text-xs font-semibold uppercase tracking-wide",
        @color == "gray" && "text-gray-600",
        @color == "blue" && "text-blue-600",
        @color == "green" && "text-green-600"
      ]}>
        {@header}
      </div>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :color, :string, default: "gray"
  slot :inner_block, required: true

  defp mock_card(assigns) do
    ~H"""
    <div class={[
      "bg-white p-3 rounded-lg shadow-sm",
      @color == "gray" && "border border-gray-200",
      @color == "blue" && "border border-blue-200",
      @color == "green" && "border border-green-200 opacity-75"
    ]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :icon_color, :string, default: "blue"
  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :icon, required: true

  def feature_card(assigns) do
    ~H"""
    <div class={[
      "text-center p-6 rounded-xl transition-colors",
      @icon_color == "blue" && "hover:bg-blue-50",
      @icon_color == "orange" && "hover:bg-orange-50"
    ]}>
      <div class={[
        "inline-flex items-center justify-center w-14 h-14",
        "text-white rounded-xl mb-4 shadow-lg",
        @icon_color == "blue" && "bg-gradient-to-br from-blue-500 to-blue-600",
        @icon_color == "orange" && "bg-gradient-to-br from-orange-500 to-orange-600",
        @icon_color == "blue-alt" && "bg-gradient-to-br from-blue-600 to-blue-700"
      ]}>
        <%= render_slot(@icon) %>
      </div>
      <h3 class="text-xl font-bold text-gray-900 mb-2">{@title}</h3>
      <p class="text-gray-600">{@description}</p>
    </div>
    """
  end
end
