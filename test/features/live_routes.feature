Feature: Live routes in edict blocks
  Live routes get the mount guard through a live_session.

  Scenario: A live route inside an edict block mounts guarded
    Given a live route for "project" with permission "read" inside an edict block
    When alice mounts the view with a granted role
    Then the mount continues with her authorization document assigned

  Scenario: A live route inside an edict block rejects a user without the role
    Given a live route for "project" with permission "read" inside an edict block
    And user "bob" has no roles
    When bob mounts the view
    Then the mount halts with a redirect
