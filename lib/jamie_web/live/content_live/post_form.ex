defmodule JamieWeb.ContentLive.PostForm do
  use JamieWeb, :live_view
  @moduledoc false

  alias Jamie.Content

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.office flash={@flash} current_scope={@current_scope} full_bleed>
      <div class="editor-split">
        <div class="editor-pane">
          <.form
            for={@form}
            id="editor-form"
            phx-change="validate"
            phx-debounce="1500"
            phx-submit="save"
            phx-hook="SaveShortcut"
          >
            <.input
              field={@form[:title]}
              label="Title"
              type="text-naked"
              placeholder="Post title"
              phx-debounce="1500"
              required
            />

            <.input
              field={@form[:status]}
              type="select-naked"
              label="Status"
              options={Enum.map(Content.Post.statuses(), &{String.capitalize(to_string(&1)), &1})}
            />

            <.input
              type="text-naked"
              field={@form[:description]}
              label="Description"
              placeholder="Brief description"
              phx-debounce="1500"
            />

            <.input
              field={@form[:markdown]}
              type="textarea-naked"
              label="Content (Markdown)"
              class="textarea w-full flex-1 font-mono min-h-96"
              placeholder="Write your post in markdown..."
              phx-hook="SignImageUrl"
              phx-debounce="1500"
            />

            <div class="mt-4 flex items-center gap-2">
              <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
                Save Post
              </button>
              <button
                :if={@live_action == :edit}
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="toggle-preview"
              >
                <.icon
                  name={if @show_preview, do: "hero-eye-slash", else: "hero-eye"}
                  class="size-4"
                />
                {if @show_preview, do: "Hide preview", else: "Show preview"}
              </button>
            </div>
          </.form>
        </div>

        <div :if={@live_action == :edit and @show_preview} class="preview-pane">
          <iframe id="post-preview" src={~p"/posts/#{@post.slug}"} title="Post preview" />
        </div>
      </div>
    </Layouts.office>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :show_preview, true)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("toggle-preview", _params, socket) do
    {:noreply, update(socket, :show_preview, &(!&1))}
  end

  def handle_event("sign-image-url", %{"name" => name}, socket) do
    host = Application.get_env(:jamie, :images)[:host]
    bucket = Application.get_env(:ex_aws, :s3)[:bucket]
    # The prefix must be part of the S3 key, not just the public URL —
    # otherwise we sign a PUT for the bucket root and link to /posts/.
    key = "posts/" <> Ecto.UUID.generate() <> Path.extname(name)

    {:ok, url} =
      :s3
      |> ExAws.Config.new([])
      |> ExAws.S3.presigned_url(:put, bucket, key)

    {:noreply,
     push_event(socket, "page-loading-stop", %{
       name: name,
       url: url,
       public_url: "https://#{host}/#{key}"
     })}
  end

  @impl true
  def handle_event("validate", %{"post" => post_params}, socket) do
    changeset =
      socket.assigns.post
      |> Content.change_post(post_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"post" => post_params}, socket) do
    save_post(socket, socket.assigns.live_action, post_params)
  end

  defp save_post(socket, :new, post_params) do
    case Content.create_post(post_params) do
      {:ok, post} ->
        {:noreply,
         socket
         |> put_flash(:info, "Post Saved")
         |> push_navigate(to: ~p"/office/posts/#{post.id}")}

      %Ecto.Changeset{} = changeset ->
        {:noreply,
         socket
         |> put_flash(:error, "could not save post")
         |> assign(form: to_form(changeset))}
    end
  end

  defp save_post(socket, :edit, post_params) do
    post = socket.assigns.post

    case Content.update_post(post, post_params, post.updated_at) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:post, updated)
         |> assign(:form, to_form(Content.change_post(updated)))
         |> put_flash(:info, "Post updated successfully.")}

      {:error, :conflict} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "This post was changed in another tab. Reload to see the latest version before saving again."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp apply_action(socket, :new, _params) do
    post = %Content.Post{}
    changeset = Content.change_post(post)

    socket
    |> assign(:page_title, "new post")
    |> assign(:post, post)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit, params) do
    post = Content.get_post!(params["id"])

    changeset =
      Content.change_post(post)

    socket
    |> assign(:page_title, "Editing #{post.title}")
    |> assign(:post, post)
    |> assign(:form, to_form(changeset))
  end
end
