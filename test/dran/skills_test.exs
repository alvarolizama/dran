defmodule Dran.SkillsTest do
  @moduledoc """
  Gate W1 (contrato de skills remotos): la tabla, el contrato de wire y el
  read-scope del lector.

  - P1: el skill es una entidad con el molde de `goals`/`plans` — `visibility`
    (default `private`) + `owner_user_id`, slug único por dueño — y se lee con
    `Dran.ContentVisibility.filter(scope, :skill)`.
  - P2: dos identidades distintas no se ven entre sí, ni en el índice ni en el
    detalle.
  - P3/P4: el contrato de wire (`name` + `description` + `body` + `version` +
    `content_hash`) y el hash calculado sobre el CUERPO.
  """

  use Dran.DataCase, async: false

  alias Dran.Accounts
  alias Dran.Skills
  alias Dran.Skills.Skill

  setup do
    u = System.unique_integer([:positive])

    {:ok, owner} = Accounts.create_user(%{email: "skill-owner-#{u}@example.com", name: "Owner"})

    {:ok, stranger} =
      Accounts.create_user(%{email: "skill-stranger-#{u}@example.com", name: "Stranger"})

    %{owner: owner, stranger: stranger}
  end

  describe "la tabla y el molde de la casa (P1)" do
    test "un skill nace privado, con dueño, versión 1 y el hash de su cuerpo", %{owner: owner} do
      skill = insert_skill!(owner, %{"slug" => "notas", "body" => "# Hola"})

      assert skill.visibility == "private"
      assert skill.owner_user_id == owner.id
      assert skill.version == 1
      assert skill.name == "notas"
      assert skill.content_hash == Skills.content_hash("# Hola")
    end

    test "el slug es único por dueño, y dos dueños pueden sostener el mismo", %{
      owner: owner,
      stranger: stranger
    } do
      insert_skill!(owner, %{"slug" => "mismo"})
      insert_skill!(stranger, %{"slug" => "mismo"})

      assert {:error, changeset} = insert_skill(owner, %{"slug" => "mismo"})
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "el changeset es la ÚNICA puerta: nombre fuera de formato, descripción de 61 y cuerpo vacío",
         %{owner: owner} do
      assert {:error, changeset} = insert_skill(owner, %{"slug" => "Bad Name"})
      assert errors_on(changeset)[:slug]

      # El formato válido: letra inicial, después a-z, 0-9, `_` y `-`.
      assert Skills.change_skill(%Skill{}, %{
               "slug" => "guion-bajo_2",
               "name" => "guion-bajo_2",
               "description" => "d",
               "body" => "# x"
             }).valid?

      assert {:error, changeset} =
               insert_skill(owner, %{"description" => String.duplicate("a", 61)})

      assert errors_on(changeset)[:description]

      assert {:error, changeset} = insert_skill(owner, %{"body" => ""})
      assert errors_on(changeset)[:body]
    end
  end

  describe "el read-scope es el del lector (P1, P2)" do
    test "el índice del lector trae lo propio y no lo ajeno privado", %{
      owner: owner,
      stranger: stranger
    } do
      mine = insert_skill!(owner, %{"slug" => "mio"})
      theirs = insert_skill!(stranger, %{"slug" => "ajeno"})

      reader_ids = fn user ->
        Skills.list_skills(scope: {:reader, user.id}) |> Enum.map(& &1.id)
      end

      assert mine.id in reader_ids.(owner)
      refute theirs.id in reader_ids.(owner)
      assert theirs.id in reader_ids.(stranger)
      refute mine.id in reader_ids.(stranger)
    end

    test "lo público lo lee cualquiera y lo privado ajeno se lee como inexistente", %{
      owner: owner,
      stranger: stranger
    } do
      public = insert_skill!(owner, %{"slug" => "publico", "visibility" => "public"})
      private = insert_skill!(owner, %{"slug" => "privado"})

      assert Skills.get_skill("publico", scope: {:reader, stranger.id}).id == public.id

      # Sin fuga de existencia: fuera del scope NO se resuelve (nil, no un raise).
      assert Skills.get_skill("privado", scope: {:reader, stranger.id}) == nil
      assert Skills.get_skill(private.slug, scope: {:reader, owner.id}).id == private.id
    end

    test "el filtro de destino y el orden del listado", %{owner: owner} do
      insert_skill!(owner, %{"slug" => "zeta"})
      insert_skill!(owner, %{"slug" => "alfa", "visibility" => "public"})

      scope = {:reader, owner.id}

      slugs = fn opts -> Skills.list_skills([scope: scope] ++ opts) |> Enum.map(& &1.slug) end

      assert slugs.([]) == ["alfa", "zeta"]
      assert slugs.(visibility: "public") == ["alfa"]
      assert slugs.(visibility: "private") == ["zeta"]
      assert slugs.(order: "updated") == ["alfa", "zeta"]
    end
  end

  describe "el hash es del CUERPO (P4)" do
    test "el mismo cuerpo deja el hash igual y un cuerpo nuevo lo cambia", %{owner: owner} do
      skill = insert_skill!(owner, %{"body" => "# uno"})

      same =
        Skills.change_skill(%Skill{}, %{
          "slug" => "otro",
          "name" => "otro",
          "description" => "d",
          "body" => "# uno"
        })

      other =
        Skills.change_skill(%Skill{}, %{
          "slug" => "otro",
          "name" => "otro",
          "description" => "d",
          "body" => "# dos"
        })

      assert Ecto.Changeset.get_change(same, :content_hash) == skill.content_hash
      refute Ecto.Changeset.get_change(other, :content_hash) == skill.content_hash
    end

    test "un cambio que no toca el cuerpo no recalcula el hash", %{owner: owner} do
      skill = insert_skill!(owner, %{"body" => "# uno"})

      changed =
        Skills.change_skill(skill, %{
          "description" => "otra descripción",
          "visibility" => "public"
        })

      # La señal del versionado es el hash: sin cambio de cuerpo no hay cambio.
      assert Ecto.Changeset.get_change(changed, :content_hash) == nil
    end
  end

  describe "el contrato de wire servido (P3)" do
    test "el índice sirve sin cuerpos y con `mine` del LECTOR", %{
      owner: owner,
      stranger: stranger
    } do
      insert_skill!(owner, %{"slug" => "publico", "visibility" => "public"})

      [entry] = Skills.index_payload(Skills.list_skills(scope: {:reader, owner.id}), owner.id)

      assert entry.slug == "publico"
      assert entry.description
      assert entry.version == 1
      assert entry.content_hash
      assert entry.visibility == "public"
      assert entry.mine
      refute Map.has_key?(entry, :body)

      [read_entry] =
        Skills.index_payload(Skills.list_skills(scope: {:reader, stranger.id}), stranger.id)

      # El mismo skill es ajeno para quien lo lee y no lo escribió.
      refute read_entry.mine
    end

    test "el detalle monta el SKILL.md con frontmatter + body", %{owner: owner} do
      skill = insert_skill!(owner, %{"slug" => "montado", "body" => "# Instrucciones"})

      payload = Skills.show_payload(skill, owner.id)

      assert payload.body == "# Instrucciones"
      assert payload.version == 1
      assert payload.content_hash == skill.content_hash

      assert payload.skill_md ==
               "---\nname: montado\ndescription: \"para probar\"\n---\n\n# Instrucciones"
    end

    test "una descripción con comillas no rompe el frontmatter", %{owner: owner} do
      skill = insert_skill!(owner, %{"slug" => "citado", "description" => ~s(usa "comillas")})

      assert skill.description == ~s(usa "comillas")
      assert Skills.to_skill_md(skill) =~ ~s(description: "usa \\"comillas\\"")
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp insert_skill(owner, attrs) do
    slug = Map.get(attrs, "slug", "demo")

    attrs =
      Map.merge(
        %{"slug" => slug, "name" => slug, "description" => "para probar", "body" => "# x"},
        attrs
      )

    %Skill{}
    |> Skill.changeset(Map.put(attrs, "owner_user_id", owner.id))
    |> Dran.Repo.insert()
  end

  defp insert_skill!(owner, attrs) do
    {:ok, skill} = insert_skill(owner, attrs)
    skill
  end
end
