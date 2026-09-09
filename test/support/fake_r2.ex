defmodule Jamie.Support.FakeR2 do
  @moduledoc """
  In-memory stand-in for Jamie.Service.R2.

  Injected via the :r2 service in test config.

  put_file stashes the binary in the process dictionary
  instead of uploading; list_files returns what's been stashed.

  State lives in the process dictionary, so it's isolated per test and
  needs no setup/teardown. It does NOT cross process boundaries.
  """

  @store :fake_r2_store

  def put_file(contents, filename) do
    files = Process.get(@store, %{})
    Process.put(@store, Map.put(files, filename, contents))
    {:ok, %{status_code: 200}}
  end

  def get_file(key) do
    case Process.get(@store, %{}) do
      %{^key => contents} -> {:ok, %{body: contents}}
      _ -> {:error, :not_found}
    end
  end

  def list_files do
    files = Process.get(@store, %{})
    contents = Enum.map(files, fn {key, _} -> %{key: key} end)
    {:ok, %{body: %{contents: contents}}}
  end

  def list_objects(prefix \\ "") do
    Process.get(@store, %{})
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, prefix) end)
    |> Enum.map(fn {key, contents} -> {key, byte_size(contents)} end)
    |> Enum.sort()
  end

  def copy_file(source_key, destination_key) do
    files = Process.get(@store, %{})

    case files do
      %{^source_key => contents} ->
        Process.put(@store, Map.put(files, destination_key, contents))
        {:ok, %{status_code: 200}}

      _ ->
        {:error, :not_found}
    end
  end

  def delete_files(keys) do
    files = Process.get(@store, %{})
    Process.put(@store, Map.drop(files, keys))
    {:ok, %{status_code: 200}}
  end
end
