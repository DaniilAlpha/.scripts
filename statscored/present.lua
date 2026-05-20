local proccess = require("proccess")

---@class NamedStats<T>
---@field name string - A name for the stats.
---@field value T - A core value for the stats.
---@field risk number - A number greater than `0`, where `0` indicates a full health, and `1+` is bad or dangerous.

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
---@return string?
local function tostrign_time(time)
	time = math.abs(time)

	if -math.huge >= time or time >= math.huge then
		return "forever"
	elseif time ~= time then
		return "unknown"
	else
		local seconds = time % 60
		local minutes = math.floor(time / 60) % 60
		local hours = math.floor(time / 3600)
		return string.format("%.0f:%02.0f:%04.1f", hours, minutes, seconds)
	end
end

-- print(tostrign_time(0.05))
-- print(tostrign_time(1.05))
-- print(tostrign_time(100))
-- print(tostrign_time(1000))
-- print(tostrign_time(9001))
-- print(tostrign_time(10000000))
-- print(tostrign_time(1 / 0))
-- print(tostrign_time(0 / 0))

--- presentation ---

local present = {}

---@class BatsPresentation
---@field combo Stats<string>?
---@field is_charging boolean?
---@field remain_time string?
---@field [number] NamedStats<string>

---@class NetfacesPresentation
---@field combo Stats<string>?
---@field [number] NamedStats<string>

---@class Presentation
---@field cpu_load Stats<string>?
---@field ram Stats<string>?
---@field swap Stats<string>?
---@field fs {["/"]: Stats<string>?}
---@field bats BatsPresentation
---@field netfaces NetfacesPresentation
---@field temps NamedStats<string>[]

---@type Presentation
present.ation = {
	cpu_load = nil,
	ram = nil,
	swap = nil,
	fs = { ["/"] = nil },
	bats = { combo = nil, remain_time = nil, is_charging = nil },
	netfaces = { combo = nil },
	temps = { combo = nil },
}

---@generic T
---@param a Stats<T>
---@param b Stats<T>
---@return boolean
local function greater_risk(a, b)
	return a.risk > b.risk
end

function present.cpu()
	local cpu_load = proccess.cpu_load()
	present.ation.cpu_load = cpu_load and { value = tostring(cpu_load.value), risk = cpu_load.risk }
end

function present.mem()
	local ram, swap = proccess.mem()
	present.ation.ram = ram and { value = tostring_si(ram.value, "B"), risk = ram.risk }
	present.ation.swap = swap and { value = tostring_si(swap.value, "B"), risk = swap.risk }
end

function present.rootfs()
	local rootfs = proccess.rootfs()
	present.ation.fs["/"] = rootfs and { value = tostring_si(rootfs.value, "B"), risk = rootfs.risk }
end

function present.bats()
	local combo, bats, remain_time = proccess.bats()

	---@type NamedStats<string>[]
	local presentation_bats = {}
	for name, bat in pairs(bats) do
		presentation_bats[#presentation_bats + 1] = {
			name = name,
			value = string.format("%s%% %+.2f%%/m", bat.value.charge, bat.value.rate * 60),
			risk = bat.risk,
		}
	end
	table.sort(presentation_bats, greater_risk)

	present.ation.bats = presentation_bats
	present.ation.bats.combo = {
		value = string.format("%s%% %+.2f%%/m", combo.value.charge, combo.value.rate * 60),
		risk = combo.risk,
	}
	present.ation.bats.is_charging, present.ation.bats.remain_time = remain_time > 0, tostrign_time(remain_time)
end

function present.netfaces()
	local combo, faces = proccess.netfaces()

	---@type NamedStats<string>[]
	local presentation_netfaces = {}
	for name, face in pairs(faces) do
		presentation_netfaces[#presentation_netfaces + 1] = {
			name = name,
			value = tostring_si(face.value * 8, "bps"),
			risk = face.risk,
		}
	end
	table.sort(presentation_netfaces, greater_risk)

	present.ation.netfaces = presentation_netfaces
	present.ation.netfaces.combo = {
		value = tostring_si(combo.value * 8, "bps"),
		risk = combo.risk,
	}
end

function present.temps()
	local temps = proccess.temps()

	---@type NamedStats<string>[]
	local presentation_temps = {}
	for name, temp in pairs(temps) do
		presentation_temps[#presentation_temps + 1] = {
			name = name,
			value = math.ceil(temp.value) .. "°C",
			risk = temp.risk,
		}
	end
	table.sort(presentation_temps, greater_risk)

	present.ation.temps = presentation_temps
end

------

return present
