defmodule Edict.Test.ReadProjectPipeline do
  use Plug.Builder

  plug Edict.Plug, action: :read, entity_type: :project, param: "project_id"
end

defmodule Edict.Test.BillingProjectPipeline do
  use Plug.Builder

  plug Edict.Plug, action: :billing, entity_type: :project, param: "project_id"
end
