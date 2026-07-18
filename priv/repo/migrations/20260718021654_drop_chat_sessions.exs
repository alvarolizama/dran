defmodule Dran.Repo.Migrations.DropChatSessions do
  use Ecto.Migration

  def change, do: drop_if_exists(table(:chat_sessions))
end
