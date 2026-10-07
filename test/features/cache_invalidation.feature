Feature: Cache invalidation
  Role changes bump the user's version so the next check rebuilds the
  document from the database. Changes that alter nothing bump nothing,
  and a dead cache falls back to the database.

  Scenario: An assignment takes effect on the next check
    Given user "alice" has no roles
    And alice's project document is cached
    When alice is assigned "admin" on project "7"
    Then alice can "read" on project "7"

  Scenario: A revocation takes effect on the next check
    Given user "alice" has the role "admin" on project "7"
    And alice's project document is cached
    When alice's "admin" role on project "7" is revoked
    Then alice cannot "read" on project "7"

  Scenario: A missed broadcast still serves the stale document
    Given user "alice" has the role "admin" on project "7"
    And alice's project document is cached
    When alice's roles change in the database without a version bump
    Then alice can still "read" on project "7" from the stale cache

  Scenario: The bump, not the write, ends the staleness
    Given user "alice" has the role "admin" on project "7"
    And alice's project document is cached
    When alice's roles change in the database without a version bump
    And the version bump for alice arrives late
    Then alice cannot "read" on project "7"

  Scenario: Re-assigning an existing role bumps no version
    Given user "alice" has the role "admin" on project "7"
    And alice's project document is cached
    When alice is assigned "admin" on project "7" again
    Then alice's cached version is unchanged

  Scenario: Revoking a role the user lacks bumps no version
    Given user "alice" has no roles
    And alice's project document is cached
    When alice's missing "admin" role on project "7" is revoked
    Then alice's cached version is unchanged

  Scenario: An unavailable cache falls back to the database
    Given user "alice" has the role "admin" on project "7"
    When the cache is down and alice checks "read" on project "7"
    Then the check reads the database and allows it
