Feature: LiveView mount authorization
  Mounting checks the mount permission and assigns the document. Every role
  change re-runs the same check; losing access stops the LiveView.

  Background:
    Given the LiveView guards "read" on "project" from param "id"

  Scenario: An authorized mount continues with the document assigned
    Given user "alice" has the role "admin" on project "7"
    When alice mounts the LiveView for project "7"
    Then the mount continues with her authorization document assigned

  Scenario: An unauthorized mount halts with a redirect
    Given user "alice" has the role "viewer" on project "8"
    When alice mounts the LiveView for project "7"
    Then the mount halts with a redirect

  Scenario: A missing param denies the mount
    Given user "alice" has the role "admin" on project "7"
    When alice mounts the LiveView without the project param
    Then the mount halts with a redirect

  Scenario: An array param denies the mount
    Given user "alice" has the role "admin" on project "78"
    When alice mounts the LiveView with project params "7" and "8"
    Then the mount halts with a redirect

  Scenario: A revocation that arrives as a version bump stops the LiveView
    Given user "alice" has the role "admin" on project "7"
    And alice mounted the LiveView for project "7"
    When alice's roles are revoked and a version bump arrives
    Then the LiveView halts with a redirect

  Scenario: A surviving role keeps the LiveView open and consumes the bump
    Given user "alice" has the role "admin" on project "7"
    And alice mounted the LiveView for project "7"
    When an unrelated role change bumps alice's version
    Then the LiveView stays open and the bump never reaches handle_info

  Scenario: An action the entity type does not define raises on mount
    Given user "alice" has the role "admin" on project "7"
    When alice mounts the LiveView for project "7" with action "aprove"
    Then the mount raises ArgumentError
