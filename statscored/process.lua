local posix = require("posix")
local collect = require("collect")

---@class Stats<T>
---@field value T the core of the stats
---@field risk number greater than `0`, where `0` indicates a full health, and `1+` is bad/dangerous

local function realtime()
	local sec, nsec = posix.clock_gettime(posix.CLOCK_REALTIME)
	return sec + nsec / 1000000000
end

-------------------
--- proccessing ---
-------------------

local process = {}

---@return Stats<number>?
function process.cpu_load()
	local cpu_load = collect.cpu_load()
	return cpu_load and { value = cpu_load, risk = cpu_load / collect.CPU_COUNT }
end

---@return Stats<integer>?, Stats<integer>?
function process.mem()
	local ram, swap = collect.mem()
	return ram and { value = ram.used_kb * 1024, risk = ram.used_kb / ram.total_kb },
		swap and { value = swap.used_kb * 1024, risk = swap.used_kb / swap.total_kb }
end

---@return Stats<integer>?
function process.rootfs()
	local rootfs = collect.rootfs()
	return rootfs and { value = rootfs.free, risk = 1 - rootfs.free / rootfs.total }
end

process.bats = (function()
	local CHANGE_COUNT_STABLE, CHANGE_COUNT_MAX = 4, math.ceil(300 / 8) -- TODO replace with expiretime, so it is independent of update period
	local CRITICAL_TIME = 10 * 60
	local CHARGE_RISK, TIME_RISK = 1.0, 0.0

	---@alias BatHistory {last: BatInfo, rates: number[]}
	---@type number, {[string]: BatHistory}
	local last_time, bat_histories = 0, {}

	---@alias BatStats Stats<{charge: integer, rate: number}>
	---@return BatStats combo stats as if it was only a single battery (combined of all real ones)
	---@return boolean is_charging results in `true` if any of the external power supplies (e.g. chargers) are connected
	---@return {[string]: BatStats} individual all real batteries statuses
	return function()
		local time, bats, chargers = realtime(), collect.pses()

		---@param charge integer
		---@param rate number
		local function bat_charge_and_rate_to_stats(charge, rate)
			return {
				value = { charge = charge, rate = rate },
				risk = (1 - charge / 100) * CHARGE_RISK
					+ (rate < 0 and (charge / -rate) or 0) / CRITICAL_TIME * TIME_RISK,
			}
		end

		---@type {[string]: BatStats}
		local individual_stats = {}
		for name, bat in pairs(bats) do
			local history = bat_histories[name] or { last = bat, rates = {} }
			history.rates[#history.rates + 1] = (bat - history.last) / (time - last_time)
			if #history.rates >= CHANGE_COUNT_MAX then
				table.remove(history.rates, 1)
			end
			history.last = bat
			bat_histories[name] = history

			local rate = 0
			if #history.rates >= CHANGE_COUNT_STABLE then
				for _, v in pairs(history.rates) do
					rate = rate + v / #history.rates
				end
			end

			individual_stats[name] = bat_charge_and_rate_to_stats(bat, rate)
		end

		local total_charge, total_rate = 0, 0
		local individual_stats_count = 0
		for _, bat in pairs(individual_stats) do
			total_charge = total_charge + bat.value.charge
			total_rate = total_rate + bat.value.rate
			individual_stats_count = individual_stats_count + 1
		end

		---@type BatStats
		local combo_stats = bat_charge_and_rate_to_stats(
			math.floor(total_charge / individual_stats_count),
			total_rate / individual_stats_count
		)

		local is_charging = false
		for _, charger in pairs(chargers) do
			is_charging = is_charging or charger
		end

		last_time = time
		return combo_stats, is_charging, individual_stats
	end
end)()

process.netfaces = (function()
	local ERROR_RISK, DROPPED_RISK = 0.5, 0.1

	---@type number, {[string]: NetfaceInfo}
	local last_time, last_faces = 0, {}

	---@return {[string]: Stats<number>}
	return function()
		local time, faces = realtime(), collect.netfaces()

		---@param this NetfaceDirInfo
		---@param last NetfaceDirInfo?
		---@return Stats<number>
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

		---@type {[string]: Stats<number>}
		local individual_stats = {}
		for name, face in pairs(faces) do
			local last_face = last_faces[name]
			local rx = netface_dir_info_to_stats(face.rx, last_face and last_face.rx)
			local tx = netface_dir_info_to_stats(face.tx, last_face and last_face.tx)
			individual_stats[name] = {
				value = rx.value + tx.value,
				risk = rx.risk * 0.5 + tx.risk * 0.5,
			}
		end

		last_time, last_faces = time, faces

		return individual_stats
	end
end)()

---@return {[string]: Stats<number>}
function process.temps()
	local THERMAL_ZONE_MAX_TEMP, BAT_MAX_TEMP = 90, 45
	local BEST_TEMP, SANE_TEMP = 20, 30

	local thermal_zones = collect.thermal_zones()
	local ps_temps = collect.ps_temps()

	---@type {[string]: Stats<number>}
	local individual_stats = {}
	for name, thermal_zone in pairs(thermal_zones) do
		local max_temp_mc = thermal_zone.trip_points_mc["critical"]
			or thermal_zone.trip_points_mc["hot"]
			or thermal_zone.trip_points_mc["active"]

		local temp = thermal_zone.temp_mc / 1000
		local max_temp = max_temp_mc and (max_temp_mc / 1000) or THERMAL_ZONE_MAX_TEMP
		max_temp = max_temp >= SANE_TEMP and max_temp or THERMAL_ZONE_MAX_TEMP

		individual_stats[name] = {
			value = temp,
			risk = math.abs(temp - BEST_TEMP) / (max_temp - BEST_TEMP),
		}
	end
	for name, ps_temp in pairs(ps_temps) do
		local temp = ps_temp.temp_mc / 1000
		local max_temp = ps_temp.temp_max_mc and (ps_temp.temp_max_mc / 1000) or BAT_MAX_TEMP
		max_temp = max_temp >= SANE_TEMP and max_temp or BAT_MAX_TEMP

		individual_stats[name] = {
			value = temp,
			risk = math.abs(temp - BEST_TEMP) / (max_temp - BEST_TEMP),
		}
	end

	return individual_stats
end

---@return {[string]: Stats<integer>}
function process.coolers()
	local cooling_devices = collect.cooling_devices()

	---@type {[string]: Stats<number>}
	local individual_stats = {}
	for name, cooling_device in pairs(cooling_devices) do
		individual_stats[name] = {
			value = cooling_device.cur_state,
			risk = cooling_device.cur_state / cooling_device.max_state,
		}
	end

	return individual_stats
end

------

return process
