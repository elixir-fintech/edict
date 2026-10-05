Feature: Plug enforcement
  Requests pass only when the user holds the action on the entity named by
  the request param. Anything ambiguous or unknown fails closed.

  Background:
    Given the plug guards "read" on "project" from param "project_id"

  Scenario: An authorized request passes and assigns the document
    Given user "alice" has the role "admin" on project "7"
    When alice requests the project "7" page
    Then the request passes with her authorization document assigned

  Scenario: An unauthorized request is halted with 403
    Given user "alice" has the role "viewer" on project "8"
    When alice requests the project "7" page
    Then the request is halted with status 403

  Scenario: A missing param is denied
    Given user "alice" has the role "admin" on project "7"
    When alice requests the page without the project param
    Then the request is halted with status 403

  Scenario: An array param is denied, not joined into another ID
    Given user "alice" has the role "admin" on project "78"
    When alice requests the page with project params "7" and "8"
    Then the request is halted with status 403

  Scenario: A request without a user is denied
    Given the database holds a blank-user document for project "7"
    When a request without a user asks for project "7"
    Then the request is halted with status 403

  Scenario: An action the entity type does not define raises
    Given user "alice" has the role "admin" on project "7"
    When alice requests the project "7" page for action "aprove"
    Then the request raises ArgumentError
