local process = require("process")

--------------------
--- presentation ---
--------------------

local present = {}

---@class Presentation
---@field cpu_load Stats<number>?
---@field ram Stats<integer>?
---@field swap Stats<integer>?
---@field fs {["/"]: Stats<integer>?}
---@field bat BatStats?
---@field is_charging boolean?
---@field bats {[string]: BatStats}
---@field temps {[string]: Stats<number>}
---@field netfaces {[string]: Stats<number>}

---@type Presentation
present.ation = {
	cpu_load = nil,
	ram = nil,
	swap = nil,
	fs = { ["/"] = nil },
	bat = nil,
	is_charging = nil,
	bats = {},
	netfaces = {},
	temps = {},
}

function present.cpu_load()
	present.ation.cpu_load = process.cpu_load()
end

function present.mem()
	present.ation.ram, present.ation.swap = process.mem()
end

function present.fs()
	present.ation.fs["/"] = process.rootfs()
end

function present.bats()
	present.ation.bat, present.ation.is_charging, present.ation.bats = process.bats()
end

function present.netfaces()
	present.ation.netfaces = process.netfaces()
end

function present.temps()
	present.ation.temps = process.temps()
end

------

return present
