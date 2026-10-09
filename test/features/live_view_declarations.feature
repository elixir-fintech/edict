Feature: LiveView declarations
  Views declare their entity once; events shrink to the permission.

  Scenario: Shorthand authorize uses the module default
    Given a LiveView declared "edict_entity :project, from: :project_id"
    When it declares 'authorize "delete", :delete'
    Then the "delete" event is guarded with permission "delete" on entity type "project" from assign "project_id"

  Scenario: A list of events shares one declaration
    Given a LiveView declared "edict_entity :project, from: :project_id"
    When it declares 'authorize ["save", "publish"], :write'
    Then the "save" and "publish" events are guarded with permission "write" on entity type "project"

  Scenario: An unguarded event is reported by the audit
    Given a LiveView with handle_event clauses for "save" and "ping"
    And only "save" is declared
    When "mix edict.audit" runs
    Then it reports "ping" as undeclared and exits non-zero
