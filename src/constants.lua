--- Constants used throughout the driver.

return {
  --- Show a property in the Composer UI.
  --- @type number
  SHOW_PROPERTY = 0,

  --- Hide a property in the Composer UI.
  --- @type number
  HIDE_PROPERTY = 1,

  --- The light's buttons, as the Light V2 proxy numbers them.
  --- @type table<string, integer>
  ButtonIds = {
    TOP = 0,
    BOTTOM = 1,
    TOGGLE = 2,
  },

  --- Button action types.
  --- @type table<string, integer>
  ButtonActions = {
    RELEASE_HOLD = 0,
    PRESS = 1,
    RELEASE_CLICK = 2,
  },
}
