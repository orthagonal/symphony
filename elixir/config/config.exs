import Config

config :phoenix, :json_library, Jason

default_tasks_db =
  Path.join([File.cwd!(), "data", "symphony_tasks.db"])
  |> Path.expand()

config :symphony_elixir, SymphonyElixir.Repo,
  database: default_tasks_db,
  pool_size: 5,
  busy_timeout: 10_000

config :symphony_elixir, ecto_repos: [SymphonyElixir.Repo]

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false,
  debug_errors: true
