defmodule Jamie.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :jamie

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Runs a step of the post-image move from a release eval, e.g.

      bin/jamie eval 'Jamie.Release.move_post_images("copy")'

  There is no mix in production, so this is how `Jamie.PostImages` gets driven
  on a live box. "delete" cannot prompt from an eval, so it is only accepted as
  "delete --yes" - which is the confirmation.
  """
  def move_post_images(command) when is_binary(command) do
    load_app()

    # ExAws is only started for us by the supervision tree, which an eval never
    # boots - and it needs its HTTP client along for the ride.
    {:ok, _} = Application.ensure_all_started(:hackney)
    {:ok, _} = Application.ensure_all_started(:ex_aws)

    case command do
      "plan" -> Jamie.PostImages.plan()
      "copy" -> Jamie.PostImages.copy()
      "verify" -> Jamie.PostImages.verify()
      "delete --yes" -> Jamie.PostImages.delete()
      other -> {:error, "unknown command #{inspect(other)}"}
    end
    |> case do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
