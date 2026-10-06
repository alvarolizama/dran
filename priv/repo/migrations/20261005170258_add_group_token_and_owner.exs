defmodule Dran.Repo.Migrations.AddGroupTokenAndOwner do
  use Ecto.Migration

  # W2 (contract grupo-credencial): un grupo pasa a ser un PRINCIPAL de pleno
  # derecho — su propia credencial y su dueño.

  # `api_token` nace NULL: un grupo sin token NO autentica (nada de credenciales
  # por defecto). `owner_user_id` es el humano que responde por el grupo (el que
  # lo crea/administra): nace del owner de la instancia, que es quien hoy
  # administra `/admin/groups`. La FK es `nilify_all` para que borrar una cuenta
  # no se lleve el grupo —ni los shares que cuelgan de él— por delante.
  def up do
    alter table(:user_groups) do
      add :api_token, :string
      add :owner_user_id, references(:users, on_delete: :nilify_all)
    end

    # Único y parcial: muchos grupos sin token (NULL) conviven, y dos grupos
    # nunca comparten credencial. Es también el índice del lookup por token.
    create unique_index(:user_groups, [:api_token],
             where: "api_token IS NOT NULL",
             name: :user_groups_api_token_index
           )

    # Backfill medido, no inventado: en `dran_dev` los grupos existentes no
    # tienen dueño y el owner de la instancia es uno solo (`users.is_owner`).
    execute("""
    UPDATE user_groups
       SET owner_user_id = (SELECT u.id FROM users u WHERE u.is_owner = true ORDER BY u.id LIMIT 1)
     WHERE owner_user_id IS NULL
    """)
  end

  def down do
    drop index(:user_groups, [:api_token], name: :user_groups_api_token_index)

    alter table(:user_groups) do
      remove :owner_user_id
      remove :api_token
    end
  end
end
