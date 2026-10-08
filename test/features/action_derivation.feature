Feature: Action derivation
  Route guards derive their permission from the Phoenix action name.

  Scenario: A known Phoenix action name derives its permission
    Given "show" is aliased to "read" in the config
    When a "show" route for "project" is declared inside an edict block
    Then the route is guarded with permission "read" on entity type "project"

  Scenario: An unmapped Phoenix action name fails compilation
    Given "billing" has no alias in the config
    When a "billing" route for "project" is declared inside an edict block without "permission:"
    Then compilation fails mentioning "billing" and both remedies

  Scenario: An explicit permission option overrides the alias
    Given "show" is aliased to "read" in the config
    When a "show" route declares "permission: :billing"
    Then the route is guarded with permission "billing"

  Scenario: A permission no role grants fails compilation
    Given "show" is aliased to "read" in the config
    And no role grants "read" on "spaceship"
    When a "show" route for "spaceship" is declared inside an edict block
    Then compilation fails mentioning the entity type and the permission

  Scenario: A block permission is the controller default
    Given an edict block for "project" declares permission "write"
    When a "show" route for "project" is declared inside an edict block without "permission:"
    Then the route is guarded with permission "write" on entity type "project"
