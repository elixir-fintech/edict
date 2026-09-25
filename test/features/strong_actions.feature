Feature: Strong actions
  Strong actions are checked against the database on every check,
  so a revoked role never grants them, even from a stale cache.

  # Cabbage does not run Background steps, so each scenario states its setup.

  Scenario: A revoked role no longer grants a strong action
    Given "approve_transfer" is a strong action
    And user "alice" has the role "treasurer" on account "7"
    And alice's authorization document is cached
    When alice's "treasurer" role on account "7" is revoked without notifying the cache
    Then alice cannot "approve_transfer" on account "7"

  Scenario: A role granted without notifying the cache grants a strong action
    Given "approve_transfer" is a strong action
    And user "bob" has no roles
    And bob's authorization document is cached
    When bob is given the role "treasurer" on account "7" without notifying the cache
    Then bob can "approve_transfer" on account "7"

  Scenario: A check can opt out of a strong action
    Given "approve_transfer" is a strong action
    And user "alice" has the role "treasurer" on account "7"
    And alice's authorization document is cached
    When alice's "treasurer" role on account "7" is revoked without notifying the cache
    Then alice can "approve_transfer" on account "7" with strong: false

  Scenario: A non-strong action keeps using the cache
    Given "approve_transfer" is a strong action
    And user "alice" has the role "treasurer" on account "7"
    And alice's authorization document is cached
    When alice's "treasurer" role on account "7" is revoked without notifying the cache
    Then alice can "read" on account "7"
