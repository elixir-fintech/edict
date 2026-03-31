defimpl Edict.Entity, for: Edict.Test.Organization do
  def entity_id(org), do: to_string(org.id)
  def entity_type(_org), do: :organization
end

defimpl Edict.Entity, for: Edict.Test.Team do
  def entity_id(team), do: to_string(team.id)
  def entity_type(_team), do: :team
end

defimpl Edict.Entity, for: Edict.Test.Project do
  def entity_id(project), do: to_string(project.id)
  def entity_type(_project), do: :project
end

defimpl Edict.Entity, for: Edict.Test.Resource do
  def entity_id(resource), do: to_string(resource.uuid)
  def entity_type(_resource), do: :resource
end
