local spacing = assert(loadfile("apps/scripts/lua-spacing.lua"))("module")

local function check(name, source, expected, opts)
	local formatted = spacing.format(source, opts)
	expected = expected or source

	assert(formatted == expected, name .. ": " .. vim.inspect({ actual = formatted, expected = expected }))
	assert(spacing.format(formatted, opts) == formatted, name .. ": spacing must be idempotent")
end

-- Control blocks get separators; ordinary calls and returns stay together.
check(
	"if block",
	[[
local result = read_file(path)
if not result then
	return nil
end
process(result)
return result
]],
	[[
local result = read_file(path)

if not result then
	return nil
end

process(result)
return result
]]
)

check(
	"numeric for loop",
	[[
start()
for i = 1, 3 do
	first(i)
	second(i)
end
finish()
]],
	[[
start()

for i = 1, 3 do
	first(i)
	second(i)
end

finish()
]]
)

check(
	"generic for loop",
	[[
start()
for _, value in ipairs(values) do
	use(value)
end
finish()
]],
	[[
start()

for _, value in ipairs(values) do
	use(value)
end

finish()
]]
)

-- These syntax forms must retain their contents without extra padding.
check(
	"branches",
	[[
if ready then
	first()
	second()
elseif waiting then
	wait()
else
	stop()
end
]]
)

check(
	"tables and multiline calls",
	[[
local values = {
	1,
	2,
}
call(
	values,
	true
)
]]
)

check(
	"leading and trailing comments",
	[[
first() -- trailing
-- explains second
second()
]]
)

check(
	"long strings and comments",
	[==[
local text = [=[
first()
second()
]=]
--[[
comment
contents
]]
print(text)
]==]
)

check(
	"existing comment separator",
	[[
first()

-- already separated
second()
]]
)

check(
	"trailing long comment",
	[=[
first() --[[trailing
keep contents
]]
second()
]=]
)

check(
	"function body",
	[[
local run = function()
	first()
	second()
end
run()
]]
)

check(
	"compact ordinary statements",
	[[
local a = 1

run(a)

return a
]],
	[[
local a = 1
run(a)
return a
]]
)

check(
	"control block with trailing long comment",
	[=[
if ready then
	go()
end --[[trailing
keep contents
]]
-- next
finish()
]=],
	[=[
if ready then
	go()
end --[[trailing
keep contents
]]

-- next
finish()
]=]
)

-- Tests separate setup/actions from assertion groups and preserve manual sections.
check(
	"test assertion groups",
	[[
local value = prepare()
act(value)
assert(value.ready)
assert(value.valid)
cleanup()
]],
	[[
local value = prepare()
act(value)

assert(value.ready)
assert(value.valid)

cleanup()
]],
	{ test_file = true }
)

check(
	"manual test sections",
	[[
prepare()

act()
]],
	nil,
	{ test_file = true }
)

check(
	"separate fixture cases",
	[[
check("one", input)
check("two", input)
]],
	[[
check("one", input)

check("two", input)
]],
	{ test_file = true }
)

assert(not pcall(spacing.format, "if broken then\n"), "invalid syntax must fail safely")

-- CLI checking must fail without writing, then autofix must produce a passing file.
local fixture = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "if ready then", "\tfirst()", "end", "second()" }, fixture)

local function command(check_only)
	local args = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", "apps/scripts/lua-spacing.lua" }

	if check_only then
		table.insert(args, "--check")
	end

	table.insert(args, fixture)
	return vim.system(args, { text = true }):wait()
end

local checked = command(true)

assert(checked.code == 1 and checked.stderr:find(fixture, 1, true), "check must report file and fail")
assert(#vim.fn.readfile(fixture) == 4, "check must not modify files")
assert(command(false).code == 0, "autofix must succeed")
assert(
	vim.deep_equal(vim.fn.readfile(fixture), { "if ready then", "\tfirst()", "end", "", "second()" }),
	"autofix must insert spacing"
)
assert(command(true).code == 0, "fixed file must pass")

vim.fn.delete(fixture)
print("Lua spacing: control blocks, readable test groups, syntax preservation, idempotence and CLI checks passed")
