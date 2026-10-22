defmodule Kanban.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  # The interface language a signed-in user last chose from the locale switcher
  # (W2416), so the service announcement email can be rendered in it. NULL
  # means the user never chose one since this column was added; that email is
  # then sent in English.
  def change do
    alter table(:users) do
      add :locale, :string
    end
  end
end
