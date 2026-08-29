defmodule Dran.Repo.Migrations.WidenGoalsBodyToText do
  use Ecto.Migration

  @moduledoc """
  Goals.body was created as varchar(255) (20260820070328) — too narrow for
  the markdown bodies goals actually carry since the 20260820071215 fold
  moved them out of pages (where body was text). Any goal body over 255
  chars fails to insert/update (string_data_right_truncation).
  """

  def up do
    execute "ALTER TABLE goals ALTER COLUMN body TYPE text",
            "ALTER TABLE goals ALTER COLUMN body TYPE varchar(255)"
  end
end
