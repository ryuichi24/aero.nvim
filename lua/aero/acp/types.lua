-- Conversation records shared by protocol, history and editor collaborators.
---@class aero.acp.EditorState
---@field lines? string[] last rendered buffer text
---@field render_marks? table[] decoration layout
---@field option_lines? table<integer, table>
---@field block_lines? table<table, integer>
---@field sections? table[] fold layout
---@field fold_views? table<integer, table> window-local fold choices
---@field render_pending? boolean
---@field pending_focus? boolean
---@field decorations_enabled? boolean
---@field spinner_marks? table[]

---@class aero.acp.Block
---@field kind "user"|"agent"|"thought"|"tool"|"plan"|"permission"|"info"
---@field text? string
---@field timestamp? integer
---@field id? string tool call identity
---@field title? string
---@field status? string
---@field content? table[]
---@field image? table
---@field entries? table[] plan entries
---@field options? table[] permission choices
---@field answer? string

---@class aero.acp.PermissionRequest
---@field params table incoming protocol request
---@field respond fun(result: any, err?: table) runtime-only response callback
---@field block aero.acp.Block

return {}
