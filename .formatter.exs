# Edict's DSL macros. Exported so apps listing :edict in import_deps can write
# `on :organization, permissions: [:read]` without `mix format` adding parens.
# Calls with a do-block (role, entity_types, edict, unguarded, ...) never get
# parens, so they need no entry.
locals_without_parens = [
  # Edict.Config
  entity: 1,
  entity: 2,
  extends: 1,
  on: 2,
  on_unauthorized: 1,
  permission_aliases: 1,
  user_from_assigns: 1,
  # Edict.Enforcement.Authorize
  authorize: 2,
  edict_entity: 1,
  edict_entity: 2,
  unguarded_events: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  import_deps: [:ecto, :phoenix],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
