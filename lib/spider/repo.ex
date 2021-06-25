defmodule Spider.Repo do
  use Ecto.Repo,
    otp_app: :spider,
    adapter: Ecto.Adapters.Postgres
end
