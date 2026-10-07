Feature: Authorize event guards
  Declared LiveView events are checked before the handler runs. Denied
  events never reach it; undeclared events pass through untouched.

  Background:
    Given a LiveView guarding "delete" with "delete" and "update" with "write" on project from assign "project_id"

  Scenario: An allowed event reaches the handler
    Given user "alice" has the role "admin" on project "7"
    When alice sends the "delete" event for project "7"
    Then the event continues to the handler

  Scenario: A denied event calls on_unauthorized and never reaches the handler
    Given user "bob" has the role "viewer" on project "7"
    When bob sends the "delete" event for project "7"
    Then the event halts with a redirect

  Scenario: An undeclared event passes through
    Given user "bob" has the role "viewer" on project "7"
    When bob sends the undeclared "ping" event for project "7"
    Then the event continues to the handler

  Scenario: A missing entity assign denies the event
    Given user "alice" has the role "admin" on project "7"
    When alice sends the "delete" event without the project assign
    Then the event halts with a redirect

  Scenario: A missing document fails the event closed
    Given the socket has no authorization document
    When alice sends the "delete" event for project "7"
    Then the event raises instead of reaching the handler

  Scenario: An action the entity type does not define raises when the event arrives
    Given user "alice" has the role "admin" on project "7"
    When alice sends the "typo" event for project "7"
    Then the event raises ArgumentError
