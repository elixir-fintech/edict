Feature: Atomic role changes
  Roles that must commit together with other writes go through Edict.Multi:
  nothing is invalidated until the transaction commits, and a rollback
  invalidates nothing.

  Background:
    Given a project "7" exists

  Scenario: An assigned role commits and invalidates after the commit
    Given user "alice" has no roles
    When alice is assigned "admin" on project "7" inside a Multi transaction
    Then the transaction commits and alice can "read" on project "7"

  Scenario: No invalidation happens before the commit
    Given user "alice" has no roles
    When a Multi transaction assigning alice "admin" on project "7" is paused before commit
    Then alice's cached version is still the pre-transaction one

  Scenario: A failed step rolls everything back and invalidates nothing
    Given user "alice" has no roles
    When a Multi transaction assigns alice an unknown role on project "7"
    Then the transaction fails and alice has no roles and no version bump

  Scenario: An Edict step under a plain transaction fails the transaction
    Given user "alice" has no roles
    When an Edict step runs inside a plain Repo transaction
    Then the transaction rolls back and alice has no roles

  Scenario: A Multi transaction inside another transaction raises
    When a Multi transaction starts inside another transaction
    Then it raises ArgumentError

  Scenario: A revoked role commits and takes effect
    Given user "alice" has the role "admin" on project "7"
    When alice's "admin" on project "7" is revoked inside a Multi transaction
    Then the transaction commits and alice cannot "read" on project "7"
