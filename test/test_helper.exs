ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Dran.Repo, :manual)

# Force synchronous augmentation/embedding scheduling for the whole suite.
# With `schedule_async: true` (the runtime default), `Brain.create_page/1`
# and `Brain.update_page/2` spawn Task.Supervisor tasks (PageAugmenter /
# Embeddings) that outlive the test and keep using the SQL sandbox's shared
# connection after the owner stops. When the owner stops, the connection is
# torn down under those tasks — and any task mid-checkout takes the shared
# connection down with it, failing whatever test owns it next with
# DBConnection.OwnershipError / "client exited". Tests that configure
# inference explicitly still control their own `:inference` env.
base_inference = Application.get_env(:dran, :inference) || []
Application.put_env(:dran, :inference, Keyword.put(base_inference, :schedule_async, false))
