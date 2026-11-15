-- Public companion facade. Keep one host table so existing lifecycle overrides retain their meaning.
local M = require("aero.companion.host")
M.dispatch = require("aero.companion.dispatch").dispatch
return M
