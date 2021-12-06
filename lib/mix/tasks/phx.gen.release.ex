defmodule Mix.Tasks.Phx.Gen.Release do
  @shortdoc "Generates release files and optional Dockerfile for release-based deployments"

  @moduledoc """
  Generates release files and optional Dockerfile for release-based deployments.

  The following release files are created:

    * `lib/app_name/release.exs` - A release module containing tasks for running
      migrations inside a release

    * `rel/overlays/bin/migrate` - A migrate script for conveniently invoking
      the release system migrations

    * `rel/overlays/bin/server` - A server script for conveniently invoking
      the release system with environment variables to start the phoenix web server

  Note, the `rel/overlays` directory is copied into the release build by default when
  running `mix release`.

  When the `--docker` flag is passed, the following docker files are generated:

    * `Dockerfile` - The Dockerfile for use in any standard docker deployment

    * `.dockerignore` - A docker ignore file with standard elixir defaults

  For extended release configuration, the `mix release.init`task can be used
  in addition to this task. See the `Mix.Release` docs for more details.
  """

  use Mix.Task

  @doc false
  def run(args) do
    docker? = "--docker" in args
    ecto? = "--ecto" in args || Code.ensure_loaded?(Ecto)

    if Mix.Project.umbrella?() do
      Mix.raise("mix phx.gen.release is not supported in umbrella applications")
    end

    app = Mix.Phoenix.otp_app()
    app_namespace = Mix.Phoenix.base()

    binding = [
      app_namespace: app_namespace,
      otp_app: app,
      elixir_vsn: System.version(),
      otp_vsn: otp_vsn()
    ]

    Mix.Phoenix.copy_from(paths(), "priv/templates/phx.gen.release", binding, [
      {:eex, "rel/server.sh.eex", "rel/overlays/bin/server"}
    ])

    if ecto? do
      Mix.Phoenix.copy_from(paths(), "priv/templates/phx.gen.release", binding, [
        {:eex, "rel/migrate.sh.eex", "rel/overlays/bin/migrate"},
        {:eex, "release.ex", Mix.Phoenix.context_lib_path(app, "release.ex")}
      ])
    end

    if docker? do
      Mix.Phoenix.copy_from(paths(), "priv/templates/phx.gen.release", binding, [
        {:eex, "Dockerfile.eex", "Dockerfile"},
        {:eex, "dockerignore.eex", ".dockerignore"}
      ])
    end

    File.chmod!("rel/overlays/bin/server", 0o700)
    if ecto?, do: File.chmod!("rel/overlays/bin/migrate", 0o700)

    Mix.shell().info("""

    Your application is ready to be deployed in a release!

        # To start your system
        _build/dev/rel/#{app}/bin/#{app} start

        # To start your system with the Phoenix server running
        _build/dev/rel/#{app}/bin/server
        #{ecto? && ecto_instructions(app)}
    Once the release is running:

        # To connect to it remotely
        _build/dev/rel/#{app}/bin/#{app} remote

        # To stop it gracefully (you may also send SIGINT/SIGTERM)
        _build/dev/rel/#{app}/bin/#{app} stop

    To list all commands:

        _build/dev/rel/#{app}/bin/#{app}
    """)

    ecto? &&
      post_install_instructions("config/runtime.exs", ~r/ECTO_IPV6/, """
      [warn] Conditional IPV6 support missing from runtime configuration.

      Add the following to your config/runtime.exs:

          ipv6? = System.get_env("ECTO_IPV6") == "true"

          config :#{app}, #{app_namespace}.Repo,
            ...,
            socket_options: if(ipv6?, do: [:inet6], else: [])
      """)

    post_install_instructions("config/runtime.exs", ~r/PHX_SERVER/, """
    [warn] Conditional server startup is missing from runtime configuration.

    Add the following to your config/runtime.exs:

        server? = System.get_env("PHX_SERVER") == "true"

        config :#{app}, #{app_namespace}.Endpoint,
          ...,
          server: server?
    """)

    post_install_instructions("config/runtime.exs", ~r/PHX_HOST/, """
    [warn] Environment based URL export is missing from runtime configuration.

    Add the following to your config/runtime.exs:

        host = System.get_env("PHX_HOST") || "example.com"

        config :#{app}, #{app_namespace}.Endpoint,
          ...,
          url: [host: host, port: 443]
    """)
  end

  defp ecto_instructions(app) do
    """

        # To run migrations
        _build/dev/rel/#{app}/bin/migrate
    """
  end

  defp paths do
    [".", :phoenix]
  end

  defp post_install_instructions(path, matching, msg) do
    case File.read(path) do
      {:ok, content} ->
        unless content =~ matching, do: Mix.shell().info(msg)

      {:error, _} ->
        Mix.shell().info(msg)
    end
  end

  def otp_vsn do
    major = to_string(:erlang.system_info(:otp_release))
    path = Path.join([:code.root_dir(), "releases", major, "OTP_VERSION"])

    with {:ok, content} <- File.read(path),
         {:ok, %Version{} = vsn} <- Version.parse(String.trim_trailing(content)) do
      "#{vsn.major}.#{vsn.minor}.#{vsn.patch}"
    else
      _ ->
        IO.warn("unable to read OTP minor version at #{path}. Falling back to #{major}.0.0")
        "#{major}.0.0"
    end
  end
end
