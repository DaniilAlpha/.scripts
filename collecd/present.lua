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
---@return number, SiPrefix
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

	return size, PREFIXES[math.min(prefix_i, #PREFIXES)]
end

--- core loop ---

while true do
	local time = os.time()

	if time - cpu_load_time >= CPU_LOAD_PERIOD then
		cpu_load_time = time

		local cpu_load = proccess.cpu_load()
		if cpu_load then
			print("CPU LOAD", string.format("%.2f (%.2f risk)", cpu_load.value, cpu_load.risk))
		end
	end

	if time - ram_swap_time >= RAM_SWAP_PERIOD then
		ram_swap_time = time

		local mem, swap = proccess.mem()
		if mem then
			local readable_value, readable_prefix = readable_si_size(mem.value)
			print("RAM", string.format("%.2f%s (%.2f risk)", readable_value, readable_prefix, mem.risk))
		end
		if swap then
			local readable_value, readable_prefix = readable_si_size(swap.value)
			print("SWAP", string.format("%.2f%s (%.2f risk)", readable_value, readable_prefix, swap.risk))
		end
	end

	if time - rootfs_time >= ROOTFS_PERIOD then
		rootfs_time = time

		local rootfs = proccess.rootfs()
		if rootfs then
			local readable_value, readable_prefix = readable_si_size(rootfs.value)
			print("ROOT", string.format("%.2f%s (%.2f risk)", readable_value, readable_prefix, rootfs.risk))
		end
	end

	if time - bats_time >= BATS_PERIOD then
		bats_time = time

		local bats, remain_time = proccess.bats()
		for name, bat in pairs(bats) do
			print(
				"BAT " .. name,
				string.format("%.0f%% %+.2f%%/m (%.2f risk)", bat.value.charge, bat.value.rate * 60, bat.risk)
			)
		end
		print(
			"TIME UNTIL",
			remain_time <= 0 and "discharge" or "full charge",
			string.format("%.2fh", math.abs(remain_time / 3600))
		)
	end

	if time - netfaces_time >= NETFACES_PERIOD then
		netfaces_time = time

		local faces = proccess.netfaces()
		for name, face in pairs(faces) do
			print(
				"NETFACE " .. name,
				string.format(
					"rx: %.2f Mbps (%.2f risk)",
					(face.rx.value + face.tx.value) * 8 / 1048576,
					face.rx.risk * 0.5 + face.tx.risk * 0.5
				)
			)
		end
	end

	if time - temps_time >= TEMPS_PERIOD then
		temps_time = time

		local temps = proccess.temps()
		for name, temp in pairs(temps) do
			print("TEMP " .. name, string.format("%.2fC (%.2f risk)", temp.value, temp.risk))
		end
	end

	posix.sleep(1)
end
