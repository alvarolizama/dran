defmodule Dran.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  @doc """
  Adds the per-user UI language.

  English is the app default, so existing rows are backfilled with `"en"`
  rather than translated to Spanish — a user upgrades into the default and can
  switch to Spanish from Account settings.
  """
  def change do
    alter table(:users) do
      add :locale, :string, default: "en"
    end
  end
end
