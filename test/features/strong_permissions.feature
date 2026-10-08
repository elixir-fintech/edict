Feature: Strong permissions
  Strong permissions are checked against the database on every check,
  so a revoked role never grants them, even from a stale cache. Strength
  is scoped per entity type: the same permission name can be strong on
  one entity type and served from the cache on another.

  Background:
    Given "approve_transfer" is a strong permission on "account"

  Scenario: A revoked role no longer grants a strong permission
    Given user "alice" has the role "treasurer" on account "7"
    And alice's authorization document is cached
    When alice's "treasurer" role on account "7" is revoked without notifying the cache
    Then alice cannot "approve_transfer" on account "7"

  Scenario: A role granted without notifying the cache grants a strong permission
    Given user "bob" has no roles
    And bob's authorization document is cached
    When bob is given the role "treasurer" on account "7" without notifying the cache
    Then bob can "approve_transfer" on account "7"

  Scenario: A check can opt out of a strong permission
    Given user "alice" has the role "treasurer" on account "7"
    And alice's authorization document is cached
    When alice's "treasurer" role on account "7" is revoked without notifying the cache
    Then alice can "approve_transfer" on account "7" with strong: false

  Scenario: A permission that is not strong on the entity type keeps using the cache
    Given user "alice" has the role "treasurer" on account "7"
    And alice's authorization document is cached
    When alice's "treasurer" role on account "7" is revoked without notifying the cache
    Then alice can "read" on account "7"

  Scenario: The same permission name is strong on one entity type and cached on another
    Given "approve_transfer" is not a strong permission on "invoice"
    And user "alice" has the role "treasurer" on invoice "7"
    And alice's authorization document is cached
    When alice's "treasurer" role on invoice "7" is revoked without notifying the cache
    Then alice can "approve_transfer" on invoice "7"
