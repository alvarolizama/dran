defmodule DranWeb.VisibilityLiveTest do
  @moduledoc """
  Gate W6 (P3 + P4 + P5-UI): superficies LiveView de la visibilidad.

  - memory_live NO ofrece un control de alcance de lectura: el alcance lo
    resuelve la política única (`Dran.ContentVisibility`) con la identidad del
    lector. El toggle «todo | solo míos» del modelo v1 se retiró (persistía una
    preferencia que nadie leía desde W3, así que mentía).
  - settings expone los toggles de compartición del workspace.
  """
  use DranWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dran.Memory
  alias Dran.Repo
  alias Dran.Accounts.User

  setup do
    original = Application.get_env(:dran, :inference)

    Application.put_env(:dran, :inference,
      base_url: "http://localhost:8000/v1",
      api_key: "test-key",
      embedding_model: "Qwen3-Embedding",
      chat_model: "Qwen3.5-9B",
      timeout: 5_000,
      req_plug: {Req.Test, Dran.Inference.Client},
      schedule_async: false,
      embedding_dimensions: 1024
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:dran, :inference)
      else
        Application.put_env(:dran, :inference, original)
      end
    end)

    stub_embeddings()
    :ok
  end

  defp create_user(unique, role \\ nil) do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        email: "vl-#{unique}@dran.test",
        api_token: "vl-#{unique}",
        name: "VL #{unique}"
      })
      |> Repo.insert()

    {user, role}
  end

  defp login(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{
      "user" => user.email,
      "workspace_slug" => nil,
      # La bandera que el login cachea: el shell de /admin/* decide con ella.
      "is_owner" => user.is_owner
    })
  end

  # W3: el toggle «todo | solo míos» y la semántica de workspace compartido /
  # aislado murieron con la visibilidad por ítem (own ∪ public ∪ shared). Lo que
  # VIVE es que la superficie no vuelva a ofrecer un alcance que no gobierna:
  # /memory monta el control de DESTINO (de `ResourceComponents`, el de todas
  # las secciones) y ningún control de lectura.
  describe "memory_live — el alcance lo decide la política, no la superficie" do
    test "el toggle v1 no existe y el único control de scope es el del destino", %{conn: conn} do
      unique = System.unique_integer([:positive])
      ws = Dran.DataCase.ensure_workspace!()
      {owner, _} = create_user(unique * 10 + 1)
      owner = owner |> Ecto.Changeset.change(is_owner: true) |> Repo.update!()

      # La instancia COMPARTE memoria: el caso exacto en el que el toggle v1 se
      # ofrecía. Ya no aparece — el alcance sale de la política.
      assert ws.share_memory == true

      {:ok, fact, :created} =
        Memory.add(%{
          "workspace_id" => ws.id,
          "content" => "Hecho del dueño #{unique}",
          "owner_user_id" => owner.id
        })

      {:ok, view, html} = conn |> login(owner) |> live(~p"/memory")

      assert html =~ "Hecho del dueño #{unique}"

      refute has_element?(view, "#memory-scope-toggle")
      refute has_element?(view, "#memory-scope-all")
      refute has_element?(view, "#memory-scope-own")
      # Ni la copia cruda del control retirado: los msgid salieron del catálogo,
      # así que `t/1` devolvería el propio msgid — se afirma el texto literal.
      refute html =~ "Memory scope"
      refute html =~ "Only mine"

      # El ÚNICO control de scope de la casa —el destino del hecho— sigue
      # montado para su dueño, con el mismo molde de todas las secciones.
      assert has_element?(view, "#memory-scope-#{fact.id}")
      assert has_element?(view, "#memory-visibility-#{fact.id}")
    end
  end

  describe "settings — los toggles de compartición ya no existen" do
    test "el form de Automation no los ofrece ni los manda, y sigue guardando lo suyo",
         %{conn: conn} do
      # El modelo v1 (workspace-wide share_memory / share_pages) murió: la
      # lectura se resuelve por ÍTEM (Dran.ContentVisibility + content_shares),
      # así que la página dejó de ofrecer un control que no gobernaba nada.
      unique = System.unique_integer([:positive])
      ws = Dran.DataCase.ensure_workspace!()
      {owner, _} = create_user(unique * 10 + 9)
      owner = owner |> Ecto.Changeset.change(is_owner: true) |> Repo.update!()

      {:ok, view, _html} = conn |> login(owner) |> live(~p"/admin/instance")

      # El form de automatización (donde vivían los toggles) está en su tab.
      view |> element("button[phx-value-tab='brain_tuning']") |> render_click()

      refute has_element?(view, "#workspace-share-memory")
      refute has_element?(view, "#workspace-share-pages")
      refute has_element?(view, ~s{[name="workspace[share_memory]"]})
      refute has_element?(view, ~s{[name="workspace[share_pages]"]})

      # Y el form sigue guardando lo que SÍ gobierna.
      html =
        render_submit(view, "save", %{
          "workspace" => %{"worker_max_pages" => "7", "summary_language" => "auto"}
        })

      assert html =~ "Settings saved"

      reloaded = Dran.Knowledge.get_workspace!(ws.id)
      assert reloaded.worker_max_pages == 7
      # Las columnas quedan (decisión D2: retiro de UI, sin migración) y ningún
      # save de la página las toca.
      assert reloaded.share_memory == true
      assert reloaded.share_pages == true
    end
  end

  # Mismo stub determinístico que los otros tests de memoria.
  defp stub_embeddings do
    Req.Test.stub(Dran.Inference.Client, fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      input = extract_embed_input(body)
      Req.Test.json(conn, embeddings_response(embedding_for(input)))
    end)
  end

  defp extract_embed_input(body) do
    case Jason.decode(body) do
      {:ok, %{"input" => [input | _]}} when is_binary(input) -> input
      {:ok, %{"input" => input}} when is_binary(input) -> input
      _ -> ""
    end
  end

  defp embedding_for(input) do
    idx = rem(:erlang.phash2(input), 1024)
    List.duplicate(0.0, idx) ++ [1.0] ++ List.duplicate(0.0, 1023 - idx)
  end

  defp embeddings_response(vec) do
    %{
      "object" => "list",
      "data" => [%{"object" => "embedding", "index" => 0, "embedding" => vec}],
      "model" => "Qwen3-Embedding",
      "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
    }
  end
end
