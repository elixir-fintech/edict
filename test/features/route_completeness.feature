Feature: Route completeness
  A router using Edict.Router compiles only when every route is declared
  or explicitly unguarded.

  Scenario: A route outside every block fails compilation
    Given the router uses Edict.Router
    When a route is declared outside any edict block
    Then compilation fails instructing to declare it or use unguarded

  Scenario: An unguarded route compiles and passes
    Given the router uses Edict.Router
    And a route is declared inside an unguarded block
    When any user requests that route
    Then the request passes without an Edict decision

  Scenario: A live route outside every block fails compilation
    Given the router uses Edict.Router
    When a live route is declared outside any edict block
    Then compilation fails instructing to declare it or use unguarded

  Scenario: A live block without a permission fails compilation
    Given the router uses Edict.Router
    When a live route is declared inside an edict block without a permission
    Then compilation fails instructing to declare the block's permission

  Scenario: A router not using Edict.Router is untouched
    Given the application also has a plain Phoenix router
    When a route is declared in it outside any edict block
    Then that router compiles without Edict errors
