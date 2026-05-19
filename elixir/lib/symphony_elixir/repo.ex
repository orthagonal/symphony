defmodule SymphonyElixir.Repo do
  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3
end
