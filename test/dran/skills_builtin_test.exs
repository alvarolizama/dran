defmodule Dran.SkillsBuiltinTest do
  @moduledoc """
  Los skills de SISTEMA: el catálogo que Dran sirve por DEFAULT a toda
  credencial que consume su API.

  - el contenido es el repo (`hermes_plugin/dran/skills/<slug>/SKILL.md`), embebido al compilar;
  - el sync es idempotente, versiona el cambio de cuerpo y poda lo que se retira;
  - lo lee TODO scope — incluido el de GRUPO, que por la Constraint 3 lee
    exactamente lo compartido a su grupo: el built-in se suma aparte y sin
    arrastrar el contenido público ajeno;
  - no lo escribe ninguna credencial: el slug está reservado y las escrituras del
    contexto lo rechazan.
  """

  use Dran.DataCase, async: false

  alias Dran.Accounts
  alias Dran.ContentVisibility
  alias Dran.Sharing
  alias Dran.Skills
  alias Dran.Skills.Builtin
  alias Dran.Skills.Skill

  setup do
    u = System.unique_integer([:positive])

    {:ok, owner} = Accounts.create_user(%{email: "builtin-owner-#{u}@example.com", name: "Owner"})

    {:ok, reader} =
      Accounts.create_user(%{email: "builtin-reader-#{u}@example.com", name: "Reader"})

    {:ok, group} = Sharing.create_group(%{name: "Builtin #{u}"}, owner_user_id: owner.id)

    %{owner: owner, reader: reader, group: group}
  end

  describe "el conjunto embebido (el repo es la fuente)" do
    test "son los archivos de skills/, con su slug, su descripción ≤ 60 y su cuerpo" do
      definitions = Builtin.all()

      assert length(definitions) == 9
      assert "loader" in Builtin.slugs()
      assert "skills-flow" in Builtin.slugs()

      for definition <- definitions do
        # La ruta sale de la DEFINICIÓN: la suite tiene dos raíces desde que el
        # router vive con el plugin.
        file = definition.file
        assert File.exists?(file), "#{file} should be the source of #{definition.slug}"
        assert definition.name == definition.slug
        assert String.length(definition.description) <= Skill.description_max()
        assert byte_size(definition.body) > 0
        # El cuerpo servido es el del archivo: termina con él, byte a byte.
        assert String.ends_with?(File.read!(file), definition.body)
      end
    end

    test "el sync los deja sin dueño, públicos y marcados como del sistema" do
      assert %{created: 9, updated: 0, pruned: 0, total: 9} = Builtin.sync!()

      rows = Skills.list_system_skills()
      assert length(rows) == 9

      for row <- rows do
        assert row.system
        assert is_nil(row.owner_user_id)
        assert row.visibility == "public"
        assert row.version == 1
        assert row.content_hash == Skill.content_hash(row.body)
      end
    end

    test "es idempotente: sin cambios no escribe una sola fila" do
      Builtin.sync!()
      before = rows_snapshot()

      assert %{created: 0, updated: 0, pruned: 0} = Builtin.sync!()

      assert rows_snapshot() == before
    end

    test "un cuerpo distinto bumpea la versión, y un flow retirado se poda" do
      Builtin.sync!()
      [first | rest] = Builtin.all()
      changed = %{first | body: first.body <> "\n\n# Paso nuevo\n"}

      assert %{updated: 1, created: 0, pruned: 0} = Skills.sync_system_skills([changed | rest])

      row = Skills.get_system_skill(first.slug)
      assert row.version == 2
      assert row.content_hash == Skill.content_hash(changed.body)

      # El flow que ya no se sirve deja de servirse (es contenido de código, no
      # datos de nadie) y volver a servir el set completo lo restaura.
      assert %{pruned: 1} = Skills.sync_system_skills(rest)
      assert is_nil(Skills.get_system_skill(first.slug))

      assert %{created: 1} = Builtin.sync!()
      assert Skills.get_system_skill(first.slug).version == 1
    end
  end

  describe "la lectura: los built-ins los ve CUALQUIER scope" do
    setup do
      Builtin.sync!()
      :ok
    end

    test "el lector personal y el privilegiado los ven", %{reader: reader} do
      assert length(Skills.list_skills(scope: {:reader, reader.id})) == 9
      assert length(Skills.list_skills(scope: :all)) == 9
      assert Skills.count_skills(scope: {:reader, reader.id}) == 9
      assert %Skill{slug: "loader"} = Skills.get_skill("loader", scope: {:reader, reader.id})
    end

    test "el token de GRUPO los ve, sin arrastrar el contenido público ajeno", %{
      owner: owner,
      group: group
    } do
      # Un skill AJENO público: la Constraint 3 dice que un grupo NO lo lee.
      other =
        insert_skill!(owner, %{
          "slug" => "ajeno-publico",
          "description" => "de otro",
          "visibility" => "public"
        })

      scope = {:group, group.id}

      slugs = scope |> then(&Skills.list_skills(scope: &1)) |> Enum.map(& &1.slug)
      assert length(slugs) == 9
      refute other.slug in slugs
      assert "loader" in slugs

      assert Skills.count_skills(scope: scope) == 9
      assert %Skill{slug: "plan-flow"} = Skills.get_skill("plan-flow", scope: scope)
      assert is_nil(Skills.get_skill(other.slug, scope: scope))
    end

    test "el opt no pisa los filtros ni la dirección del caller", %{reader: reader} do
      scope = {:reader, reader.id}

      # El detalle resuelve SU slug: la cláusula de sistema no puede convertirse
      # en «cualquier built-in» (fue el bug que este test cazó).
      assert Skills.get_skill("plan-flow", scope: scope).slug == "plan-flow"
      assert is_nil(Skills.get_skill("no-existe", scope: scope))

      # Y el filtro del call site sigue mandando: con `visibility: "private"` no
      # aparece ningún built-in (son públicos).
      assert Skills.list_skills(scope: scope, visibility: "private") == []
      assert length(Skills.list_skills(scope: scope, visibility: "public")) == 9
    end

    test "el filtro de destino no los esconde del grupo, y el detalle respeta el opt", %{
      group: group
    } do
      scope = {:group, group.id}
      row = Skills.get_system_skill("loader")

      # El mismo juicio en las dos formas: la query (`filter/4`) y la fila ya
      # cargada (`visible?/4`). Sin el opt, el built-in no se lee con grupo.
      assert ContentVisibility.visible?(row, scope, :skill, system_field: :system)
      refute ContentVisibility.visible?(row, scope, :skill)
    end
  end

  describe "la escritura: un built-in no la acepta de nadie" do
    setup do
      Builtin.sync!()
      :ok
    end

    test "actualizar y borrar un built-in es un error explícito" do
      row = Skills.get_system_skill("loader")

      assert {:error, :system_readonly} = Skills.update_skill(row, %{"body" => "# otro"})
      assert {:error, :system_readonly} = Skills.delete_skill(row)
      assert Skills.get_system_skill("loader").body == row.body
    end

    test "el slug de un built-in está reservado: el alta no crea un homónimo", %{owner: owner} do
      # Con slug explícito, el error va al slug.
      assert {:error, changeset} =
               Skills.create_skill(
                 %{"slug" => "loader", "name" => "otro", "description" => "d", "body" => "# x"},
                 owner_user_id: owner.id
               )

      assert %{slug: [_]} = errors_on(changeset)

      # Sin slug, la dirección se deriva del name: el error va también al name,
      # que es el campo que el operador escribió.
      assert {:error, changeset} =
               Skills.create_skill(
                 %{"name" => "loader", "description" => "d", "body" => "# x"},
                 owner_user_id: owner.id
               )

      assert %{name: [_], slug: [_]} = errors_on(changeset)
      assert length(Skills.list_system_skills()) == 9
    end

    test "un slug libre sigue naciendo normal", %{owner: owner} do
      assert {:ok, skill} =
               Skills.create_skill(
                 %{"name" => "mi-flow", "description" => "propio", "body" => "# mío"},
                 owner_user_id: owner.id
               )

      refute skill.system
      assert skill.owner_user_id == owner.id
      assert skill.visibility == "private"
    end
  end

  defp rows_snapshot do
    Skills.list_system_skills()
    |> Enum.map(&{&1.slug, &1.version, &1.content_hash, &1.updated_at})
  end

  defp insert_skill!(owner, attrs) do
    attrs =
      Map.merge(
        %{"name" => attrs["slug"], "description" => "d", "body" => "# x"},
        attrs
      )

    {:ok, skill} = Skills.create_skill(attrs, owner_user_id: owner.id)
    skill
  end
end
