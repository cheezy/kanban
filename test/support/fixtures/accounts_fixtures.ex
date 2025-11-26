defmodule Kanban.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Kanban.Accounts` context.
  """

  import Ecto.Query

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_confirmation_instructions(user, url)
      end)

    {:ok, user} = Accounts.confirm_user(token)

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.html_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Accounts.UserToken
    |> where([t], t.token == ^token)
    |> Kanban.Repo.update_all(set: [authenticated_at: authenticated_at])
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt =
      DateTime.utc_now(:second)
      |> DateTime.add(amount_to_add, unit)

    Accounts.UserToken
    |> where([ut], ut.token == ^token)
    |> Kanban.Repo.update_all(set: [inserted_at: dt, authenticated_at: dt])
  end
end
