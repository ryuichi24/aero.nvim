std = "luajit"
globals = { "vim" }
max_line_length = false
-- Intentional shadowing, discarded return values, and documented no-op branches
-- are common here; retain checks for unused locals/arguments and undefined names.
ignore = { "311", "4", "542" }
self = false
