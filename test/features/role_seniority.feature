Feature: Role seniority
  A role can extend another; effective permissions are the transitive union.

  Scenario: An extending role grants the inherited permission
    Given the role "viewer" grants "read" on "project"
    And the role "editor" extends "viewer" and grants "write" on "project"
    And alice holds only the role "editor" on project "7"
    Then alice can "read" on project "7"

  Scenario: Seniority composes transitively
    Given the role "viewer" grants "read" on "project"
    And the role "editor" extends "viewer" and grants "write" on "project"
    And the role "admin" extends "editor" and grants "delete" on "project"
    And alice holds only the role "admin" on project "7"
    Then alice can "read" on project "7"

  Scenario: Assigning a senior role stores only that role
    Given the role "admin" extends "editor"
    When alice is assigned "admin" on project "7"
    Then the database holds a single role row for alice on project "7"
    And her document lists only "admin"

  Scenario: An unknown parent fails compilation
    When a role extends the undefined role "ghost"
    Then compilation fails naming "ghost"

  Scenario: An inheritance cycle fails compilation
    When the role "a" extends "b" and the role "b" extends "a"
    Then compilation fails naming the cycle
