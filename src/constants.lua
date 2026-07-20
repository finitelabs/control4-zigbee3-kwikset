--- Constants shared across the driver. `src/lib/utils.lua` and
--- `src/lib/values.lua` (from the template) require this module for the
--- property show/hide flags passed to C4:SetPropertyAttribs.

return {
  --- Show a property in the Composer UI.
  --- @type number
  SHOW_PROPERTY = 0,

  --- Hide a property in the Composer UI.
  --- @type number
  HIDE_PROPERTY = 1,
}
