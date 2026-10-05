Feature: Role write validation
  Writes validate roles and entity types against the config, reject blank
  identities, and report no-ops honestly so callers can tell what changed.

  Scenario: An unknown role is rejected
    When "alice" is assigned the unknown role "superadmin" on project "7"
    Then the write fails with invalid_role and stores nothing

  Scenario: An unknown entity type is rejected
    When "alice" is assigned "admin" on unknown entity "spaceship" "7"
    Then the write fails with invalid_entity_type and stores nothing

  Scenario: A blank entity ID is rejected
    When "alice" is assigned "admin" on project ""
    Then the write fails with a changeset error and stores nothing

  Scenario: A blank user ID is rejected
    When a blank user is assigned "admin" on project "7"
    Then the write fails with a changeset error and stores nothing

  Scenario: Re-assigning an existing role is a no-op
    Given user "alice" has the role "admin" on project "7"
    When "alice" is assigned "admin" on project "7" again
    Then the write reports already_assigned

  Scenario: Revoking a role the user lacks reports not_found
    Given user "alice" has no roles
    When alice's missing "admin" role on project "7" is revoked
    Then the write reports not_found

  Scenario: Bulk assign skips existing roles and returns only new ones
    Given user "alice" has the role "admin" on project "7"
    When "alice" is assigned "admin" on projects "7" and "8"
    Then only the project "8" assignment is returned

  Scenario: Bulk assign with one bad entry stores nothing
    Given user "alice" has no roles
    When "alice" is bulk-assigned "admin" on project "7" and unknown entity "spaceship" "9"
    Then the write fails with invalid_entity_type and stores nothing

  Scenario: Revoking an entity clears every user's roles on it
    Given user "alice" has the role "admin" on project "7"
    And user "bob" has the role "viewer" on project "7"
    When project "7" is deleted and its roles are revoked
    Then alice and bob hold no roles on project "7"
