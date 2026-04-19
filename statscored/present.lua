#!/usr/bin/lua

table.unpack = table.unpack or unpack
local posix = require("posix")
local proccess = require("proccess")

local TICK_PERIOD = 4
local CPU_LOAD_PERIOD_TICKS = 1
local RAM_SWAP_PERIOD_TICKS = 1
local ROOTFS_PERIOD_TICKS = 64
local TEMPS_PERIOD_TICKS = 8
local BATS_PERIOD_TICKS = 16
local NETFACES_PERIOD_TICKS = 2

--- formatters ---

---@param size number
---@alias SiPrefix ""|"k"|"M"|"G"|"T"
---@param prefix SiPrefix?
---@return number, SiPrefix
local function optimal_si_prefix(size, prefix)
	local PREFIXES = { "", "k", "M", "G", "T" }

	local prefix_i = 1
	for i, p in ipairs(PREFIXES) do
		if p == prefix then
			prefix_i = i
			break
		end
	end

	while size > 1024 do
		size = size / 1024
		prefix_i = prefix_i + 1
	end

	return size, PREFIXES[math.min(prefix_i, #PREFIXES)]
end

---@param value number
---@param unit string?
---@param char_count number?
---@return string
local function tostring_si(value, unit, char_count)
	unit = unit or ""
	char_count = char_count or 5

	if -math.huge >= value or value >= math.huge then
		return string.rep(" ", char_count - 3) .. "inf" .. unit
	elseif value ~= value then
		return string.rep(" ", char_count - 3) .. "nan" .. unit
	else
		local prefix
		value, prefix = optimal_si_prefix(value, prefix)
		char_count = char_count - (prefix == "" and 0 or 1)

		local digit_count = math.min(math.max(math.ceil(math.log(value, 10)), 1), char_count - 1)
		return string.format("%" .. char_count .. "." .. char_count - 1 - digit_count .. "f%s", value, prefix .. unit)
	end
end

-- print(tostring_si(-(1. / 0), "u"))
-- print(tostring_si((1. / 0), "u"))
-- print(tostring_si((0. / 0), "u"))
-- print(tostring_si(0, "u"))
-- print(tostring_si(0.531, "u"))
-- print(tostring_si(0.33, "u"))
-- print(tostring_si(0.5, "u"))
-- print(tostring_si(3, "u"))
-- print(tostring_si(33, "u"))
-- print(tostring_si(840, "u"))
-- print(tostring_si(6577, "u"))
-- print(tostring_si(99999, "u"))
-- print(tostring_si(816333, "u"))
-- print(tostring_si(5131483, "u"))

---@param time number
---@return string
local function tostrign_time(time)
	time = math.abs(time)

	if time >= math.huge then
		return "forever"
	else
		local seconds = time % 60
		local minutes = math.floor(time / 60) % 60
		local hours = math.floor(time / 3600)

		return string.format("%d:%02d:%04.1f", hours, minutes, seconds)
	end
end

---@param obj any
---@return string
local function serialize(obj)
	local t = type(obj)

	if t == "number" or t == "boolean" then
		return tostring(obj)
	elseif t == "string" then
		return string.format("%q", obj)
	elseif t == "table" then
		local parts = {}
		for k, v in pairs(obj) do
			local kt = type(k)
			---@type string?
			local k_slzd = nil
			if kt == "number" or kt == "boolean" then
				k_slzd = tostring(k)
			elseif kt == "string" then
				k_slzd = string.format("%q", k)
			end

			if k_slzd then
				local serialized_v = serialize(v)
				parts[#parts + 1] = "[" .. k_slzd .. "] = " .. serialized_v
			else
				parts[#parts + 1] = "--[[unaccessible " .. kt .. " key]]"
			end
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	elseif t == "function" then
		return "function(...) return (...) end"
	else
		return "nil --[[unserializable " .. t .. "]]"
	end
end

--- core loop ---

---@class Presentation
---@field cpu_load Stats<string>?
---@field ram Stats<string>?
---@field swap Stats<string>?
---@field fs {["/"]: Stats<string>?}
---@field bats {[1]: {[string]: Stats<string>}, remain_time: string?, is_charging: boolean?}
---@field temps {[string]: Stats<string>}
---@field netfaces {[string]: Stats<string>}

---@type Presentation
local presentation = {
	cpu_load = nil,
	ram = nil,
	swap = nil,
	fs = { ["/"] = nil },
	bats = { {}, remain_time = nil, is_charging = nil },
	remain_time = nil,
	temps = {},
	netfaces = {},
}

local tick = 0
while true do
	if tick % CPU_LOAD_PERIOD_TICKS == 0 then
		local cpu_load = proccess.cpu_load()
		presentation.cpu_load = cpu_load and { value = tostring(cpu_load.value), risk = cpu_load.risk }
	end

	if tick % RAM_SWAP_PERIOD_TICKS == 0 then
		local ram, swap = proccess.mem()
		presentation.ram = ram and { value = tostring_si(ram.value, "B"), risk = ram.risk }
		presentation.swap = swap and { value = tostring_si(swap.value, "B"), risk = swap.risk }
	end

	if tick % ROOTFS_PERIOD_TICKS == 0 then
		local rootfs = proccess.rootfs()
		presentation.fs["/"] = rootfs and { value = tostring_si(rootfs.value, "B"), risk = rootfs.risk }
	end

	if tick % BATS_PERIOD_TICKS == 0 then
		local bats, remain_time = proccess.bats()
		for name, bat in pairs(bats) do
			presentation.bats[1][name] = {
				value = string.format("%s%% %+.2f%%/m", bat.value.charge, bat.value.rate * 60),
				risk = bat.risk,
			}
		end
		presentation.bats.remain_time, presentation.bats.is_charging = tostrign_time(remain_time), remain_time > 0
	end

	if tick % TEMPS_PERIOD_TICKS == 0 then
		local temps = proccess.temps()
		for name, temp in pairs(temps) do
			presentation.temps[name] = { value = math.ceil(temp.value) .. "°C", risk = temp.risk }
		end
	end

	if tick % NETFACES_PERIOD_TICKS then
		local faces = proccess.netfaces()
		for name, face in pairs(faces) do
			presentation.netfaces[name] = {
				value = tostring_si((face.rx.value + face.tx.value) * 8, "bps"),
				risk = face.rx.risk * 0.5 + face.tx.risk * 0.5,
			}
		end
	end

	local f = io.open("/dev/shm/statscore.lua", "w")
	if f then
		f:write("return " .. serialize(presentation))
		f:close()
	end

	posix.sleep(TICK_PERIOD)
	tick = tick + 1
end
