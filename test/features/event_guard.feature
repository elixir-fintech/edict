Feature: Event guard
  Every LiveView routed in an edict block has its events checked.

  Scenario: An undeclared event fails
    Given a LiveView routed in an edict block that authorizes "save"
    When alice sends the event "ping"
    Then the event fails naming "ping" and both remedies
    And the view's handle_event never runs

  Scenario: An unguarded event reaches the view without a check
    Given a LiveView routed in an edict block that lists "validate" in unguarded_events
    When alice sends the event "validate"
    Then the view's handle_event runs

  Scenario: A declared event is still checked
    Given a LiveView routed in an edict block that authorizes "delete" with permission "delete"
    And alice holds the role "viewer" on project "7"
    When alice sends the event "delete"
    Then the event is denied through on_unauthorized

  Scenario: Two views in one block are guarded per view
    Given an edict block routing two LiveViews
    And the first authorizes "save" and the second authorizes "publish"
    When alice sends "publish" to the first view
    Then the event fails naming "publish" and both remedies

  Scenario: A routed LiveView without Authorize fails to mount
    Given a LiveView routed in an edict block that does not use Edict.Enforcement.Authorize
    When alice mounts the routed view
    Then the mount fails naming the module and "use Edict.Enforcement.Authorize"

  Scenario: A nested child of a routed view mounts without Authorize
    Given a LiveView routed in an edict block that renders a nested LiveView
    And the nested LiveView does not use Edict.Enforcement.Authorize
    When alice opens the routed view in a browser
    Then the nested LiveView mounts
