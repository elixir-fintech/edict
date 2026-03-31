defmodule Edict.Test.Repo do
  use Ecto.Repo,
    otp_app: :edict,
    adapter: Ecto.Adapters.Postgres
end
