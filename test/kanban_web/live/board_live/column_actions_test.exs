defmodule KanbanWeb.BoardLive.ColumnActionsTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  alias KanbanWeb.BoardLive.ColumnActions

  # column_deletion_prompt/1 in every locale, for an empty column and for one,
  # zero and many of each count. ja and zh have a single plural form; fr reads
  # 0 as singular.
  @prompts %{
    "en" => {
      "Delete this column?",
      "Delete this column? It holds 1 open task and 1 archived task, which will be deleted with it.",
      "Delete this column? It holds 0 open tasks and 12 archived tasks, which will be deleted with it.",
      "Delete this column? It holds 7 open tasks and 0 archived tasks, which will be deleted with it."
    },
    "de" => {
      "Diese Spalte löschen?",
      "Diese Spalte löschen? Sie enthält 1 offene Aufgabe und 1 archivierte Aufgabe, die mit ihr gelöscht werden.",
      "Diese Spalte löschen? Sie enthält 0 offene Aufgaben und 12 archivierte Aufgaben, die mit ihr gelöscht werden.",
      "Diese Spalte löschen? Sie enthält 7 offene Aufgaben und 0 archivierte Aufgaben, die mit ihr gelöscht werden."
    },
    "es" => {
      "¿Eliminar esta columna?",
      "¿Eliminar esta columna? Contiene 1 tarea abierta y 1 tarea archivada, que se eliminarán con ella.",
      "¿Eliminar esta columna? Contiene 0 tareas abiertas y 12 tareas archivadas, que se eliminarán con ella.",
      "¿Eliminar esta columna? Contiene 7 tareas abiertas y 0 tareas archivadas, que se eliminarán con ella."
    },
    "fr" => {
      "Supprimer cette colonne ?",
      "Supprimer cette colonne ? Elle contient 1 tâche ouverte et 1 tâche archivée, qui seront supprimées avec elle.",
      "Supprimer cette colonne ? Elle contient 0 tâche ouverte et 12 tâches archivées, qui seront supprimées avec elle.",
      "Supprimer cette colonne ? Elle contient 7 tâches ouvertes et 0 tâche archivée, qui seront supprimées avec elle."
    },
    "pt" => {
      "Excluir esta coluna?",
      "Excluir esta coluna? Ela contém 1 tarefa aberta e 1 tarefa arquivada, que serão excluídas com ela.",
      "Excluir esta coluna? Ela contém 0 tarefas abertas e 12 tarefas arquivadas, que serão excluídas com ela.",
      "Excluir esta coluna? Ela contém 7 tarefas abertas e 0 tarefas arquivadas, que serão excluídas com ela."
    },
    "ja" => {
      "この列を削除しますか？",
      "この列を削除しますか？オープンなタスク 1 件とアーカイブ済みタスク 1 件が含まれており、列と一緒に削除されます。",
      "この列を削除しますか？オープンなタスク 0 件とアーカイブ済みタスク 12 件が含まれており、列と一緒に削除されます。",
      "この列を削除しますか？オープンなタスク 7 件とアーカイブ済みタスク 0 件が含まれており、列と一緒に削除されます。"
    },
    "zh" => {
      "删除此列？",
      "删除此列？其中有1 个开放任务和1 个已归档任务，将随该列一起删除。",
      "删除此列？其中有0 个开放任务和12 个已归档任务，将随该列一起删除。",
      "删除此列？其中有7 个开放任务和0 个已归档任务，将随该列一起删除。"
    }
  }

  describe "column_deletion_prompt/1" do
    test "covers all seven locales" do
      assert @prompts |> Map.keys() |> Enum.sort() == ~w(de en es fr ja pt zh)
    end

    for {locale, {empty, singular, zero_open, zero_archived}} <- @prompts do
      @locale locale
      @expected [
        {%{open: 0, archived: 0}, empty},
        {%{open: 1, archived: 1}, singular},
        {%{open: 0, archived: 12}, zero_open},
        {%{open: 7, archived: 0}, zero_archived}
      ]

      test "renders the empty, singular, zero and many forms in #{locale}" do
        Gettext.with_locale(KanbanWeb.Gettext, @locale, fn ->
          for {counts, expected} <- @expected do
            assert ColumnActions.column_deletion_prompt(counts) == expected
          end
        end)
      end
    end
  end

  describe "with_column_on_board/3" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      %{user: user, board: board, column: column_fixture(board)}
    end

    test "runs the function while the column is still on the board", %{
      board: board,
      column: column
    } do
      socket = socket(board)

      assert ColumnActions.with_column_on_board(socket, column.id, &{:ran, &1}) == {:ran, socket}
    end

    test "flashes not found and skips the function for a column deleted elsewhere", %{
      user: user,
      board: board,
      column: column
    } do
      {:ok, _} = Kanban.Columns.delete_column(column, user)
      board_socket = socket(board)

      assert {:noreply, socket} =
               ColumnActions.with_column_on_board(board_socket, column.id, fn _ ->
                 flunk("ran for a deleted column")
               end)

      assert socket.assigns.flash == %{"error" => "Column not found on this board"}
    end

    test "flashes not found for a column on another board", %{user: user, column: column} do
      other_socket = user |> board_fixture() |> socket()

      assert {:noreply, socket} =
               ColumnActions.with_column_on_board(other_socket, column.id, fn _ ->
                 flunk("ran for another board's column")
               end)

      assert socket.assigns.flash == %{"error" => "Column not found on this board"}
    end
  end

  defp socket(board) do
    %Phoenix.LiveView.Socket{
      router: KanbanWeb.Router,
      assigns: %{__changed__: %{}, board: board, flash: %{}},
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }
  end
end
