#!/usr/bin/lua

table.unpack = table.unpack or unpack
local posix = require("posix")
local proccess = require("proccess")

local CPU_LOAD_PERIOD = 5
local RAM_SWAP_PERIOD = 5
local ROOTFS_PERIOD = 300
local TEMPS_PERIOD = 30
local BATS_PERIOD = 30
local NETFACES_PERIOD = 10

local cpu_load_time = 0
local ram_swap_time = 0
local rootfs_time = 0
local temps_time = 0
local bats_time = 0
local netfaces_time = 0

--- formatters ---

---@param size number
---@alias SiPrefix ""|"k"|"M"|"G"|"T"
---@param prefix SiPrefix?
---@alias ReadableSiSize {[1]: number, prefix: SiPrefix}
---@return ReadableSiSize
local function readable_si_size(size, prefix)
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

	return { size, prefix = PREFIXES[math.min(prefix_i, #PREFIXES)] }
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
---@field cpu_load Stats<number>?
---@field ram Stats<ReadableSiSize>?
---@field swap Stats<ReadableSiSize>?
---@field fs {["/"]: Stats<ReadableSiSize>?}
---@field bats {[1]: {[string]: Stats<{charge: integer, rate: number}>}, remain_time: number?}
---@field temps {[string]: Stats<number>}
---@field netfaces {[string]: Stats<ReadableSiSize>}

---@type Presentation
local presentation = {
	cpu_load = nil,
	ram = nil,
	swap = nil,
	fs = { ["/"] = nil },
	bats = { {}, remain_time = nil },
	remain_time = nil,
	temps = {},
	netfaces = {},
}

while true do
	local time = os.time()

	if time - cpu_load_time >= CPU_LOAD_PERIOD then
		cpu_load_time = time

		local cpu_load = proccess.cpu_load()
		presentation.cpu_load = cpu_load
	end

	if time - ram_swap_time >= RAM_SWAP_PERIOD then
		ram_swap_time = time

		local ram, swap = proccess.mem()
		presentation.ram = ram and { value = readable_si_size(ram.value), risk = ram.risk }
		presentation.swap = swap and { value = readable_si_size(swap.value), risk = swap.risk }
	end

	if time - rootfs_time >= ROOTFS_PERIOD then
		rootfs_time = time

		local rootfs = proccess.rootfs()
		presentation.fs["/"] = rootfs and { value = readable_si_size(rootfs.value), risk = rootfs.risk }
	end

	if time - bats_time >= BATS_PERIOD then
		bats_time = time

		local bats, remain_time = proccess.bats()
		presentation.bats = { bats, remain_time = remain_time }
		-- print(
		-- 	"TIME UNTIL",
		-- 	remain_time <= 0 and "discharge" or "full charge",
		-- 	string.format("%.2fh", math.abs(remain_time / 3600))
		-- )
	end

	if time - temps_time >= TEMPS_PERIOD then
		temps_time = time

		local temps = proccess.temps()
		presentation.temps = temps
	end

	if time - netfaces_time >= NETFACES_PERIOD then
		netfaces_time = time

		local faces = proccess.netfaces()
		for name, face in pairs(faces) do
			presentation.netfaces[name] = {
				value = readable_si_size((face.rx.value + face.tx.value) * 8),
				risk = face.rx.risk * 0.5 + face.tx.risk * 0.5,
			}
		end
	end

	local f = io.open("/dev/shm/statscore.lua", "w")
	if f then
		f:write("return " .. serialize(presentation))
		f:close()
	end

	posix.sleep(1)
end
