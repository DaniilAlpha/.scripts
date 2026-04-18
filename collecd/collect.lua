local lfs = require("lfs")

--- @param path string
--- @param whats ("*a"|"*l"|"*n")[]
--- @return (any)...
local function read(path, whats)
	local file = path:sub(1, 1) == "|" and io.popen(path:sub(2), "r") or io.open(path, "r")
	if not file then
		return
	end
	local result = {}
	for i, what in ipairs(whats) do
		result[i] = file:read(what)
	end
	file:close()
	return table.unpack(result)
end

--- collection ---

local collect = {}

---@alias NetfaceDirInfo {data_amount: integer, error_count: integer, dropped_count: integer}
---@alias NetfaceInfo {rx: NetfaceDirInfo, tx: NetfaceDirInfo}
--- @return {[string]: NetfaceInfo}
function collect.netfaces()
	---@param name string
	---@return NetfaceInfo?
	local function collect_netface_stats(name)
		--- @type number?, number?, number?, number?, number?, number?
		local rx_bytes, rx_errors, rx_dropped, tx_bytes, tx_errors, tx_dropped =
			read("/sys/class/net/" .. name .. "/statistics/rx_bytes", { "*n" }),
			read("/sys/class/net/" .. name .. "/statistics/rx_errors", { "*n" }),
			read("/sys/class/net/" .. name .. "/statistics/rx_dropped", { "*n" }),
			read("/sys/class/net/" .. name .. "/statistics/tx_bytes", { "*n" }),
			read("/sys/class/net/" .. name .. "/statistics/tx_errors", { "*n" }),
			read("/sys/class/net/" .. name .. "/statistics/tx_dropped", { "*n" })
		if rx_bytes and rx_errors and rx_dropped and tx_bytes and tx_errors and tx_dropped then
			return {
				rx = { data_amount = rx_bytes, error_count = rx_errors, dropped_count = rx_dropped },
				tx = { data_amount = tx_bytes, error_count = tx_errors, dropped_count = tx_dropped },
			}
		end
	end

	--- @type {[string]: NetfaceInfo}
	local faces = {}

	for name in lfs.dir("/sys/class/net/") do
		--- @cast name string

		faces[name] = collect_netface_stats(name)
	end

	return faces
end

------

return collect
