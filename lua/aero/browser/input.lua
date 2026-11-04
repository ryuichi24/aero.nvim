-- Translate Neovim's virtual-terminal input into Pixel's embedded input protocol.
local M = {}
local arrows = { A = "up", B = "down", C = "right", D = "left", H = "home", F = "end", Z = "tab" }
local tilde = { [2] = "insert", [3] = "delete", [5] = "pageup", [6] = "pagedown" }

function M.new(send, cell)
	local pending = ""
	local function key(name, text, modifier)
		local bits = (modifier or 1) - 1
		send({
			type = "key",
			key = name,
			text = text,
			kind = "press",
			mods = {
				shift = bit.band(bits, 1) ~= 0,
				alt = bit.band(bits, 2) ~= 0,
				ctrl = bit.band(bits, 4) ~= 0,
				super = bit.band(bits, 8) ~= 0,
			},
		})
	end
	return function(data)
		pending = pending .. data
		while #pending > 0 do
			if pending:sub(1, 6) == "\027[200~" then
				local last = pending:find("\027[201~", 7, true)

				if not last then
					return
				end

				send({ type = "paste", text = pending:sub(7, last - 1) })
				pending = pending:sub(last + 6)
			elseif pending:sub(1, 2) == "\027[" then
				local sequence = pending:match("^\027%[[0-9;<:]*[A-Za-z~]")

				if not sequence then
					return
				end

				pending = pending:sub(#sequence + 1)
				local button, x, y, phase = sequence:match("^\027%[<(%d+);(%d+);(%d+)([Mm])$")
				local number, modifier, final = sequence:match("^\027%[(%d*);?(%d*)([A-Za-z~])$")

				if button then
					button = tonumber(button)
					send({
						type = "mouse",
						kind = bit.band(button, 64) ~= 0 and (button % 2 == 0 and "scrollup" or "scrolldown")
							or (phase == "m" and "up" or "down"),
						button = ({ "left", "middle", "right" })[button % 4 + 1] or "none",
						x = (tonumber(x) - 0.5) * cell[1],
						y = (tonumber(y) - 0.5) * cell[2],
						mods = {},
					})
				elseif final == "u" then
					local code = tonumber(number)

					if code then
						key(code == 9 and "tab" or vim.fn.nr2char(code), nil, tonumber(modifier))
					end
				elseif arrows[final] then
					key(arrows[final], nil, final == "Z" and 2 or tonumber(modifier))
				elseif final == "~" and tilde[tonumber(number)] then
					key(tilde[tonumber(number)], nil, tonumber(modifier))
				end
			elseif pending:byte() == 27 then
				pending = pending:sub(2)

				if #pending > 0 then
					local text = pending:match("^[%z\1-\127\194-\244][\128-\191]*")

					if text then
						pending = pending:sub(#text + 1)
						key(text, text, 3)
					end
				else
					key("escape")
				end
			else
				local byte = pending:byte()
				local count = byte < 128 and 1 or byte < 224 and 2 or byte < 240 and 3 or 4

				if #pending < count then
					return
				end

				local text = pending:sub(1, count)
				pending = pending:sub(count + 1)

				if byte == 13 then
					key("enter")
				elseif byte == 9 then
					key("tab")
				elseif byte == 127 then
					key("backspace")
				elseif byte > 0 and byte <= 26 then
					key(string.char(byte + 96), nil, 5)
				else
					key(text, text, text:match("%u") and 2 or 1)
				end
			end
		end
	end
end

return M
