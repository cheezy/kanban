defmodule Kanban.Tasks.AssigneesTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Accounts.User
  alias Kanban.Repo
  alias Kanban.Tasks.Assignees
  alias Kanban.Tasks.Task

  doctest Kanban.Tasks.Assignees

  defp disable!(user),
    do: user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()

  describe "disabled?/1" do
    test "is true only for a user whose row is disabled" do
      enabled = user_fixture()
      stale = user_fixture()
      disable!(stale)

      refute Assignees.disabled?(enabled.id)
      # `stale` still says disabled_at: nil; the answer comes from the database.
      assert stale.disabled_at == nil
      assert Assignees.disabled?(stale.id)
    end

    test "is false for an id that names no user" do
      refute Assignees.disabled?(-1)
    end

    test "is false, without querying, for an id beyond the Postgres bigint range" do
      refute Assignees.disabled?(99_999_999_999_999_999_999)
      refute Assignees.disabled?(-99_999_999_999_999_999_999)
    end
  end

  describe "validate_enabled_assignee/1" do
    test "adds an :assigned_to_id error when the change names a disabled user" do
      user = disable!(user_fixture())

      changeset =
        %Task{}
        |> Ecto.Changeset.change(assigned_to_id: user.id)
        |> Assignees.validate_enabled_assignee()

      refute changeset.valid?
      assert errors_on(changeset).assigned_to_id == [Assignees.disabled_assignee_message()]
    end

    test "adds nothing when :assigned_to_id already carries an error" do
      user = disable!(user_fixture())

      changeset =
        %Task{}
        |> Ecto.Changeset.change(assigned_to_id: user.id)
        |> Ecto.Changeset.add_error(:assigned_to_id, "is invalid")
        |> Assignees.validate_enabled_assignee()

      assert errors_on(changeset).assigned_to_id == ["is invalid"]
    end

    test "leaves an enabled new assignee alone" do
      user = user_fixture()

      changeset =
        %Task{}
        |> Ecto.Changeset.change(assigned_to_id: user.id)
        |> Assignees.validate_enabled_assignee()

      assert changeset.valid?
    end

    test "leaves an unchanged or cleared assignee alone even when disabled" do
      user = disable!(user_fixture())

      unchanged =
        %Task{assigned_to_id: user.id}
        |> Ecto.Changeset.change(title: "Renamed")
        |> Assignees.validate_enabled_assignee()

      cleared =
        %Task{assigned_to_id: user.id}
        |> Ecto.Changeset.change(assigned_to_id: nil)
        |> Assignees.validate_enabled_assignee()

      assert unchanged.valid?
      assert cleared.valid?
    end
  end

  describe "translation" do
    test "the refusal message is translated in every non-English locale" do
      for locale <- ~w(de es fr ja pt zh) do
        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            Gettext.dgettext(KanbanWeb.Gettext, "errors", Assignees.disabled_assignee_message())
          end)

        refute translated == Assignees.disabled_assignee_message(),
               "#{locale} has no translation for the disabled-assignee message"
      end
    end
  end
end
