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

compute.netfaces = (function()
	local ERROR_RISK, DROPPED_RISK = 0.5, 0.1

	local last_time, last_faces = 0, {}

	--- @return {[string]: {rx: Stats<number>, tx: Stats<number>}}
	return function()
		local time, faces = realtime(), collect.netfaces()

		--- @param this NetfaceDirInfo
		--- @param last NetfaceDirInfo?
		--- @return Stats<number>
		local function netface_dir_info_stats(this, last)
			last = last or { data_amount = 0, error_count = 0, dropped_count = 0 }
			return {
				value = (this.data_amount - last.data_amount) / (time - last_time),
				risk = (
					(this.error_count - last.error_count) * ERROR_RISK
					+ (this.dropped_count - last.dropped_count) * DROPPED_RISK
				) / (time - last_time),
			}
		end

		--- @type {[string]: {rx: Stats<number>, tx: Stats<number>}}
		local stats = {}
		for name, face in pairs(faces) do
			stats[name] = {
				rx = netface_dir_info_stats(face.rx, last_faces[name] and last_faces[name].rx),
				tx = netface_dir_info_stats(face.tx, last_faces[name] and last_faces[name].tx),
			}
		end

		last_time, last_faces = time, faces

		return stats
	end
end)()

------

return compute
