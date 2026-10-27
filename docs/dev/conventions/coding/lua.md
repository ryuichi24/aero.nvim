# Lua statement spacing

Follow these Lua statement-spacing rules:

## 1. General Lua

Separate `if`/`for` from adjacent statements, including in nested blocks; no
block-edge padding or same-line splitting. In non-test files, keep other
statements together except around function declarations or comments.
Put separators before leading comments; keep trailing long comments attached.
Applies to statements, not table fields or expressions.

```lua
local items = {}
local ready = true

if ready then
	prepare()

	for _, item in ipairs(items) do
		process(item)
	end

	finish()
end

save(items)
```

## 2. Test files

In test files, also separate direct `check(...)` calls and transitions between
`assert(...)` and other statements. Consecutive assertions may stay together;
other existing blank lines are preserved.

```lua
-- Separate assertions from setup, but not from each other.
local result = run()

assert(result)
assert(result.ok)

check("result", result.ok)
```
