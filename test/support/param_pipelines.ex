defmodule Edict.Test.ReadProjectPipeline do
  use Plug.Builder

  plug Edict.Plug, action: :read, entity_type: :project, param: "project_id"
end

defmodule Edict.Test.BillingProjectPipeline do
  use Plug.Builder

  plug Edict.Plug, action: :billing, entity_type: :project, param: "project_id"
end

defmodule Edict.Test.BillingProjectThenMarkPipeline do
  use Plug.Builder

  plug Edict.Plug, action: :billing, entity_type: :project, param: "project_id"
  plug :mark_downstream_ran

  def mark_downstream_ran(conn, _opts), do: assign(conn, :downstream_ran, true)
end
