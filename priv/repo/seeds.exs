# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Kanban.Repo.insert!(%Kanban.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Kanban.Accounts

Accounts.register_user(%{
  name: "Cheezy Morgan",
  email: "cheezy@letstango.ca",
  password: "change_me_cheezy",
  type: :admin
})

Accounts.register_user(%{
  name: "Ardita Karaj",
  email: "ardita@letstango.ca",
  password: "change_me_ardita",
  type: :admin
})
