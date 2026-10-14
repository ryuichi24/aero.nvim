-- Conversation records shared by protocol, history and editor collaborators.
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
---@field shown? integer editor-only revealed byte count
---@field cache? table editor-only formatting cache
---@field cache_src? string editor-only cache source

---@class aero.acp.PermissionRequest
---@field params table incoming protocol request
---@field respond fun(result: any, err?: table) runtime-only response callback
---@field block aero.acp.Block

return {}
