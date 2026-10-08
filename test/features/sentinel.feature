Feature: Sentinel as defense in depth
  Requests that never passed an Edict decision are denied at response time.

  Scenario: A declared request passes
    Given the sentinel is in the pipeline
    And a "show" route is declared inside an edict block for "project"
    When alice requests that route with a granted role
    Then the request passes

  Scenario: A declared live request passes the sentinel
    Given the sentinel is in the pipeline
    And a live route for "project" with permission "read" is declared inside an edict block
    When alice requests that route with a granted role
    Then the request passes

  Scenario: A declared but denied request is not double-handled
    Given the sentinel is in the pipeline
    And a "show" route is declared inside an edict block for "project"
    When alice requests that route without a granted role
    Then the denial response from the guard is kept

  Scenario: An undeclared request is denied
    Given the sentinel is in the pipeline
    And a manually wired controller without an Edict guard handles a route
    When any user requests that route
    Then the request is denied with a 403

  Scenario: Sentinel before the guard still passes declared requests
    Given the sentinel is in the pipeline and the guard is in the scope
    When alice requests a declared route with a granted role
    Then the request passes
