local posix = require("posix")
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

--- @type integer
collect.CPU_COUNT = (function()
	--- @type string
	local cpuinfo = read("/proc/cpuinfo", { "*a" })
	if not cpuinfo then
		return 1
	end

	local count = 0
	for _ in cpuinfo:gmatch("processor%s*:%s*%d+") do
		count = count + 1
	end
	return count
end)()

--- @alias CpuLoadInfo integer
--- @return CpuLoadInfo?
function collect.cpu_load()
	return read("/proc/loadavg", { "*n" })
end

---@alias MemInfo {used_kb: integer, total_kb: integer}
--- @return MemInfo?, MemInfo?
function collect.mem()
	--- @type string?
	local meminfo = read("/proc/meminfo", { "*a" })
	if meminfo then
		local ram_total, ram_free, swap_total, swap_free =
			tonumber(meminfo:match("MemTotal:%s+(%d+)")),
			tonumber(meminfo:match("MemAvailable:%s+(%d+)")),
			tonumber(meminfo:match("SwapTotal:%s+(%d+)")),
			tonumber(meminfo:match("SwapFree:%s+(%d+)"))

		local ram_used = ram_total and ram_free and ram_total - ram_free
		local swap_used = swap_total and swap_free and swap_total - swap_free

		return ram_used and ram_total and { used_kb = ram_used, total_kb = ram_total },
			swap_used and swap_total and { used_kb = swap_used, total_kb = swap_total }
	end
end

---@alias FSInfo {free: integer, total: integer}
--- @return FSInfo?
function collect.rootfs()
	local statvfs = posix.statvfs("/")
	if statvfs then
		--- @type number?, number?, number?
		local total_blocks, free_blocks, block_size = statvfs.blocks, statvfs.bfree, statvfs.frsize

		local free = free_blocks and block_size and free_blocks * block_size
		local total = total_blocks and block_size and total_blocks * block_size

		return free and total and { free = free, total = total }
	end
end

--- @alias BatInfo integer
--- @return {[string]: BatInfo}
function collect.bats()
	---@param name string
	---@return BatInfo?
	local function bat(name)
		return read("/sys/class/power_supply/" .. name .. "/capacity", { "*n" })
	end

	--- @type {[string]: BatInfo}
	local bats = {}
	for name in lfs.dir("/sys/class/power_supply/") do
		--- @cast name string
		if name:lower():find("bat") then
			bats[name] = bat(name)
		end
	end

	return bats
end

---@alias NetfaceDirInfo {data_amount: integer, error_count: integer, dropped_count: integer}
---@alias NetfaceInfo {rx: NetfaceDirInfo, tx: NetfaceDirInfo}
--- @return {[string]: NetfaceInfo}
function collect.netfaces()
	---@param name string
	---@return NetfaceInfo?
	local function netface(name)
		--- @type integer?, integer?, integer?, integer?, integer?, integer?
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
		faces[name] = netface(name)
	end

	return faces
end

-- TODO! refactor this function
--- @return {[string]: {value: number, risk: number}}
function collect.temps()
	---@param name string
	---@return string?, {value: number, risk: number}?
	local function collect_thermal_zone(name)
		local FALLBACK_THLD = 90000
		local BEST_TEMP = 20000

		---@param i number
		---@return {type: string, value: number}?
		local function collect_tp(i)
			--- @type string?, number?
			local type, temp =
				read("/sys/class/thermal/" .. name .. "/trip_point_" .. i .. "_type", { "*l" }),
				read("/sys/class/thermal/" .. name .. "/trip_point_" .. i .. "_temp", { "*n" })
			if not type or not temp then
				return
			end
			-- sanity check for invalid temps
			return temp > 0 and { type = type, value = temp } or nil
		end

		--- @type string?, number?
		local type, temp =
			read("/sys/class/thermal/" .. name .. "/type", { "*l" }),
			read("/sys/class/thermal/" .. name .. "/temp", { "*n" })
		if not type or not temp then
			return
		end
		-- filter out batteries, as we are trying to collet them separately (and they usually lack a lot of info in thermal)
		if type:lower():find("bat") then
			return
		end

		--- @type number?, number?, number?
		local hot_thld, critical_thld, active_thld
		for tp_filename in lfs.dir("/sys/class/thermal/" .. name) do
			--- @cast tp_filename string

			local tp_i = tonumber(tp_filename:match("trip_point_(%d+)_type"))
			local tp = tp_i and collect_tp(tp_i)
			if tp then
				if tp.type == "hot" then
					hot_thld = tp.value
				elseif tp.type == "critical" then
					critical_thld = tp.value
				elseif tp.type == "active" then
					active_thld = tp.value
				end
			end
		end
		local thld = critical_thld or hot_thld or active_thld or FALLBACK_THLD

		return type, {
			value = temp / 1000,
			risk = math.abs(temp - BEST_TEMP) / thld,
		}
	end

	--- @param name string
	--- @return string?, {value: number, risk: number}?
	local function collect_bat_temps(name)
		local FALLBACK_THLD = 45000
		local BEST_TEMP = 20000

		-- power_supply/*/temp* can have any units in there, thus we are guessing-converting
		local function temp_anyu_to_mc(temp_anyu)
			if temp_anyu > 1000 then -- mC
				return temp_anyu
			elseif temp_anyu > 60 then -- dC
				return temp_anyu * 100
			else -- C
				return temp_anyu * 1000
			end
		end

		--- @type number?, number?
		local temp, temp_max =
			read("/sys/class/power_supply/" .. name .. "/temp", { "*n" }),
			read("/sys/class/power_supply/" .. name .. "/temp_max", { "*n" })
		temp = temp and temp_anyu_to_mc(temp)
		temp_max = temp_max and temp_anyu_to_mc(temp_max)
		if not temp then
			return
		end
		local thld = temp_max or FALLBACK_THLD

		return name, {
			value = temp / 1000,
			risk = math.abs(temp - BEST_TEMP) / thld,
		}
	end

	--- @type {[string]: {value: number, risk: number}}
	local temps = {}

	for zone_filename in lfs.dir("/sys/class/thermal/") do
		--- @cast zone_filename string

		if zone_filename:find("thermal_zone") then
			local zone_name, zone_temp = collect_thermal_zone(zone_filename)
			if zone_name then
				temps[zone_name] = zone_temp
			end
		end
	end

	for bat_filename in lfs.dir("/sys/class/power_supply/") do
		--- @cast bat_filename string

		if bat_filename:lower():find("bat") then
			local bat_name, bat_temp = collect_bat_temps(bat_filename)
			if bat_name then
				temps[bat_name] = bat_temp
			end
		end
	end

	return temps
end

-- TODO probably show cooling devices

------

return collect
