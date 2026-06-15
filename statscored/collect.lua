local posix = require("posix")
local lfs = require("lfs")

---@param path string
---@param whats ("*a"|"*l"|"*n")[]
---@return (any)...
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

------------------
--- collection ---
------------------

local collect = {}

---@type integer
collect.CPU_COUNT = (function()
	---@type string
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

---@alias CpuLoadInfo integer
---@return CpuLoadInfo?
function collect.cpu_load()
	return read("/proc/loadavg", { "*n" })
end

---@alias MemInfo {used_kb: integer, total_kb: integer}
---@return MemInfo?, MemInfo?
function collect.mem()
	---@type string?
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
---@return FSInfo?
function collect.rootfs()
	local statvfs = posix.statvfs("/")
	if statvfs then
		---@type integer?, integer?, integer?
		local total_blocks, free_blocks, block_size = statvfs.blocks, statvfs.bfree, statvfs.frsize

		local free = free_blocks and block_size and free_blocks * block_size
		local total = total_blocks and block_size and total_blocks * block_size

		return free and total and { free = free, total = total }
	end
end

---@alias ChargerInfo boolean
---@alias BatInfo integer
---@return {[string]: BatInfo}, {[string]: ChargerInfo}
function collect.pses()
	---@param name string
	---@return {type: "Battery"|"UPS"|"Mains"|"USB"|"Wireless", capacity: integer?, online: boolean?}?
	local function ps(name)
		---@type string?, integer?, integer?
		local type, capacity, online =
			read("/sys/class/power_supply/" .. name .. "/type", { "*l" }),
			read("/sys/class/power_supply/" .. name .. "/capacity", { "*n" }),
			read("/sys/class/power_supply/" .. name .. "/online", { "*n" })
		if type then
			return { type = type, capacity = capacity, online = online and online ~= 0 }
		end
	end

	---@type {[string]: BatInfo}, {[string]: ChargerInfo}
	local bats, chargers = {}, {}
	for name in lfs.dir("/sys/class/power_supply/") do
		---@cast name string
		local info = ps(name)
		if info then
			if info.type == "Battery" then
				bats[name] = info.capacity
			else
				chargers[name] = info.online
			end
		end
	end

	return bats, chargers
end

---@alias NetfaceDirInfo {data_amount: integer, error_count: integer, dropped_count: integer}
---@alias NetfaceInfo {rx: NetfaceDirInfo, tx: NetfaceDirInfo}
---@return {[string]: NetfaceInfo}
function collect.netfaces()
	---@param name string
	---@return NetfaceInfo?
	local function netface(name)
		---@type integer?, integer?, integer?, integer?, integer?, integer?
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

	---@type {[string]: NetfaceInfo}
	local faces = {}
	for name in lfs.dir("/sys/class/net/") do
		---@cast name string
		faces[name] = netface(name)
	end

	return faces
end

---@alias TpType "hot"|"critical"|"active"|"passive"
---@alias ThermalZoneInfo {temp_mc: integer, trip_points_mc: {[TpType]: number}}
---@return {[string]: ThermalZoneInfo}
function collect.thermal_zones()
	---@param i integer
	---@return string?, ThermalZoneInfo?
	local function thermal_zone(i)
		---@param j integer
		---@return TpType?, integer?
		local function trip_point_mc(j)
			---@type TpType?, integer?
			local type, temp_mc =
				read("/sys/class/thermal/thermal_zone" .. i .. "/trip_point_" .. j .. "_type", { "*l" }),
				read("/sys/class/thermal/thermal_zone" .. i .. "/trip_point_" .. j .. "_temp", { "*n" })
			if type and temp_mc then
				return type, temp_mc
			end
		end

		---@type string?, integer?
		local type, temp_mc =
			read("/sys/class/thermal/thermal_zone" .. i .. "/type", { "*l" }),
			read("/sys/class/thermal/thermal_zone" .. i .. "/temp", { "*n" })
		if not type or not temp_mc then
			return
		end

		-- filter out batteries, as we are collecting them separately (and they usually lack info in thermal)
		if type:lower():find("bat") then
			return
		end

		---@type {[TpType]: integer}
		local trip_points_mc = {}
		for tp_filename in lfs.dir("/sys/class/thermal/thermal_zone" .. i) do
			---@cast tp_filename string
			local j = tonumber(tp_filename:match("trip_point_(%d+)_type"))
			if j then
				local tp_type, tp_temp_mc = trip_point_mc(j)
				if tp_type then
					trip_points_mc[tp_type] = tp_temp_mc
				end
			end
		end

		return type, { temp_mc = temp_mc, trip_points_mc = trip_points_mc }
	end

	---@type {[string]: ThermalZoneInfo}
	local thermal_zones = {}
	for zone_filename in lfs.dir("/sys/class/thermal/") do
		---@cast zone_filename string
		local i = tonumber(zone_filename:match("thermal_zone(%d+)"))
		if i then
			local name, info = thermal_zone(i)
			if name then
				if thermal_zones[name] then
					local j = 1
					while thermal_zones[name .. j] do
						j = j + 1
					end
					name = name .. j
				end

				thermal_zones[name] = info
			end
		end
	end

	return thermal_zones
end

---@alias PSTempInfo {type: "Battery"|"UPS"|"Mains"|"USB"|"Wireless", temp_mc: integer, temp_max_mc: integer?}
---@return {[string]: PSTempInfo}
function collect.ps_temps()
	---@param anyu integer?
	---@return integer?
	local function temp_anyu_to_mc(anyu)
		if anyu then
			-- power_supply/*/temp* can have any units in there, thus we are guessing-converting
			if anyu > 1000 then -- mC
				return anyu
			elseif anyu > 60 then -- dC
				return anyu * 100
			else -- C
				return anyu * 1000
			end
		end
	end

	---@param name string
	---@return PSTempInfo?
	local function ps_temp(name)
		---@type integer?, integer?
		local type, temp_mc, max_temp_mc =
			read("/sys/class/power_supply/" .. name .. "/type", { "*l" }),
			temp_anyu_to_mc(read("/sys/class/power_supply/" .. name .. "/temp", { "*n" })),
			temp_anyu_to_mc(read("/sys/class/power_supply/" .. name .. "/temp_max", { "*n" }))
		if type and temp_mc then
			return { type = type, temp_mc = temp_mc, temp_max_mc = max_temp_mc }
		end
	end

	---@type {[string]: PSTempInfo}
	local temps = {}
	for name in lfs.dir("/sys/class/power_supply/") do
		---@cast name string
		temps[name] = ps_temp(name)
	end

	return temps
end

---@alias CoolingDeviceInfo {cur_state: integer, max_state: integer}
---@return {[string]: CoolingDeviceInfo}
function collect.cooling_devices()
	---@param i integer
	---@return string?, CoolingDeviceInfo?
	local function cooling_device(i)
		---@type string?, integer?
		local type, cur_state, max_state =
			read("/sys/class/thermal/cooling_device" .. i .. "/type", { "*l" }),
			read("/sys/class/thermal/cooling_device" .. i .. "/cur_state", { "*n" }),
			read("/sys/class/thermal/cooling_device" .. i .. "/max_state", { "*n" })
		if type and cur_state and max_state then
			return type, { cur_state = cur_state, max_state = max_state }
		end
	end

	---@type {[string]: CoolingDeviceInfo}
	local cooling_devices = {}
	for cooling_device_filename in lfs.dir("/sys/class/thermal/") do
		---@cast cooling_device_filename string
		local i = tonumber(cooling_device_filename:match("cooling_device(%d+)"))
		if i then
			local name, info = cooling_device(i)
			if name then
				if cooling_devices[name] then
					local j = 1
					while cooling_devices[name .. j] do
						j = j + 1
					end
					name = name .. j
				end

				cooling_devices[name] = info
			end
		end
	end

	return cooling_devices
end

------

return collect
