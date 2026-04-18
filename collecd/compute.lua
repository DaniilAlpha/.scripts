local posix = require("posix")
local collect = require("collect")

--- @class Stats<T>
--- @field value T - A core value for the stats.
--- @field risk number - A number greater than `0`, where `0` indicates a full health, and `1+` is bad or dangerous.

local function realtime()
	local sec, nsec = posix.clock_gettime(posix.CLOCK_REALTIME)
	return sec + nsec / 1000000000
end

--- computation ---

local compute = {}

--- @return Stats<number>?
function compute.cpu_load()
	local cpu_load = collect.cpu_load()
	return cpu_load and { value = cpu_load, risk = cpu_load / collect.CPU_COUNT }
end

--- @return Stats<integer>?, Stats<integer>?
function compute.mem()
	local ram, swap = collect.mem()
	return ram and { value = ram.used_kb * 1024, risk = ram.used_kb / ram.total_kb },
		swap and { value = swap.used_kb * 1024, risk = swap.used_kb / swap.total_kb }
end

--- @return Stats<integer>?
function compute.rootfs()
	local rootfs = collect.rootfs()
	return rootfs and { value = rootfs.free, risk = 1 - rootfs.free / rootfs.total }
end

compute.bats = (function()
	local CHANGE_COUNT_STABLE, CHANGE_COUNT_MAX = 4, 20
	local CRITICAL_TIME = 10 * 60
	local CHARGE_RISK, TIME_RISK = 0.5, 0.5

	--- @alias BatHistory {last: BatInfo, rates: number[]}
	--- @type number, {[string]: BatHistory}
	local last_time, bat_histories = 0, {}

	--- @alias BatStats Stats<{charge: integer, rate: number}>
	--- @return {[string]: BatStats}, number
	return function()
		local time, bats = realtime(), collect.bats()

		--- @type {[string]: BatStats}
		local stats = {}
		for name, bat in pairs(bats) do
			local history = bat_histories[name] or { last = bat, rates = {} }
			history.last = bat
			history.rates[#history.rates + 1] = (bat - history.last) / (time - last_time)
			if #history.rates >= CHANGE_COUNT_MAX then
				table.remove(history.rates, 1)
			end
			bat_histories[name] = history

			local rate = 0
			if #history.rates >= CHANGE_COUNT_STABLE then
				for _, v in ipairs(history.rates) do
					rate = rate + v / #history.rates
				end
			end

			stats[name] = {
				value = { charge = bat, rate = rate },
				risk = (1 - bat / 100) * CHARGE_RISK + (rate > 0 and 0 or bat / -rate) / CRITICAL_TIME * TIME_RISK,
			}
		end

		local total_charge, total_rate = 0, 0
		for _, bat in pairs(stats) do
			total_charge = total_charge + bat.value.charge
			total_rate = total_charge + bat.value.rate
		end
		local total_remain_time = (total_rate > 0 and (#stats * 100 - total_charge) or total_charge) / total_rate

		last_time = time

		return stats, total_remain_time
	end
end)()

compute.netfaces = (function()
	local ERROR_RISK, DROPPED_RISK = 0.5, 0.1

	--- @type number, {[string]: NetfaceInfo}
	local last_time, last_faces = 0, {}

	--- @alias NetfaceStats {rx: Stats<number>, tx: Stats<number>}
	--- @return {[string]: NetfaceStats}
	return function()
		local time, faces = realtime(), collect.netfaces()

		--- @param this NetfaceDirInfo
		--- @param last NetfaceDirInfo?
		--- @return Stats<number>
		local function netface_dir_info_to_stats(this, last)
			last = last or { data_amount = 0, error_count = 0, dropped_count = 0 }
			return {
				value = (this.data_amount - last.data_amount) / (time - last_time),
				risk = (
					(this.error_count - last.error_count) * ERROR_RISK
					+ (this.dropped_count - last.dropped_count) * DROPPED_RISK
				) / (time - last_time),
			}
		end

		--- @type {[string]: NetfaceStats}
		local stats = {}
		for name, face in pairs(faces) do
			local last_face = last_faces[name]
			stats[name] = {
				rx = netface_dir_info_to_stats(face.rx, last_face and last_face.rx),
				tx = netface_dir_info_to_stats(face.tx, last_face and last_face.tx),
			}
		end

		last_time, last_faces = time, faces

		return stats
	end
end)()

--- @return {[string]: Stats<number>}
function compute.temps()
	return collect.temps()
end

------

return compute
