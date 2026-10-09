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

  Scenario: A resources declaration fails compilation
    Given the router uses Edict.Router
    When a resources declaration is made inside an edict block
    Then compilation fails instructing to declare routes individually

  Scenario: A match inside an edict block fails compilation
    Given the router uses Edict.Router
    When a match route is declared inside an edict block
    Then compilation fails instructing to use the verb macros

  Scenario: A forward outside an unguarded block fails compilation
    Given the router uses Edict.Router
    When a forward is declared outside an unguarded block
    Then compilation fails instructing to wrap it in unguarded

  Scenario: A resources declaration inside an unguarded block compiles
    Given the router uses Edict.Router
    When a resources declaration is made inside an unguarded block
    Then that router compiles without Edict errors

  Scenario: An entity_from that is not a remote capture fails compilation
    Given the router uses Edict.Router
    When an edict block takes entity_from as a module and function tuple
    Then compilation fails instructing to pass a remote capture

  Scenario: An entity_from remote capture compiles
    Given the router uses Edict.Router
    When an edict block takes entity_from as a remote capture
    Then the route is guarded with that resolver
