--!strict
-- Runs the real server entry script (src/server/init.server.luau) under Lune, over a small
-- stand-in for the parts of Roblox it touches: the services it asks for, Players, remotes, tagged
-- plot parts, instances, CFrame and task. The data store is a FakeDataStore over `records`, and
-- task.spawn and task.wait run on a FakeScheduler, so a test can move the clock and act while
-- something is still in flight.
--
-- Only what the entry script uses is modelled. A call to anything else fails, so a new service
-- or member used by the script shows up here as an error rather than passing quietly.
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local FakeClock = require("./FakeClock")
local FakeDataStore = require("./FakeDataStore")
local FakeScheduler = require("./FakeScheduler")

local SHARED: { [string]: any } = {
	Config = require("../../src/shared/Config"),
	ConfigCheck = require("../../src/shared/ConfigCheck"),
	Grid = require("../../src/shared/Grid"),
	Layout = require("../../src/shared/Layout"),
	RateLimiter = require("../../src/shared/RateLimiter"),
	Validate = require("../../src/shared/Validate"),
}

local DATA: { [string]: any } = {
	Lease = require("../../src/server/Data/Lease"),
	MemoryStore = require("../../src/server/Data/MemoryStore"),
	Migrations = require("../../src/server/Data/Migrations"),
	Profile = require("../../src/server/Data/Profile"),
	Steps = require("../../src/server/Data/Steps"),
	Store = require("../../src/server/Data/Store"),
}

local SERVER: { [string]: any } = {
	Build = require("../../src/server/Build"),
	Handlers = require("../../src/server/Handlers"),
	Plots = require("../../src/server/Plots"),
	Restore = require("../../src/server/Restore"),
	Sessions = require("../../src/server/Sessions"),
	Wallet = require("../../src/server/Wallet"),
}

-- Read once, when this module is first required. fs.readFile yields to Lune's scheduler, which a
-- test running in the runner's own thread must not do.
local SOURCE = fs.readFile("src/server/init.server.luau")

local FakeGame = {}

export type Options = {
	config: any?, -- replaces Config
	failRequire: string?, -- the name of a module whose require throws
	blockShared: boolean?, -- ReplicatedStorage:WaitForChild never returns
	start: number?, -- the clock's starting time
	records: any?, -- an existing store to start over, as a restarted server would
}

local function signal(world: any): any
	local s: any = { fns = {} }
	function s.Connect(self: any, fn: (...any) -> ())
		table.insert(self.fns, fn)
		return {
			Disconnect = function()
				local i = table.find(self.fns, fn)
				if i then
					table.remove(self.fns, i)
				end
			end,
		}
	end
	-- Each handler runs in its own thread, as Roblox does, and an error in one is logged rather
	-- than raised in whoever fired the signal.
	function s.fire(self: any, ...: any)
		for _, fn in table.clone(self.fns) do
			world:spawnLogged(fn, ...)
		end
	end
	return s
end

local function strict(name: string, members: { [string]: any }): any
	return setmetatable(members, {
		__index = function(_, key)
			error(`FakeGame: {name}.{tostring(key)} is not modelled`, 2)
		end,
	})
end

-- A stand-in module reference: what `script.Build` or `Shared:WaitForChild("Config")` gives the
-- entry script, and what its `require` turns back into the module.
local function moduleRef(name: string, value: any): any
	return { __moduleName = name, __module = value }
end

-- A CFrame that handles what the script does with one: a position and a turn about Y, and
-- multiplication. `R` is the rotation as nine numbers, row by row.
local CFrameMeta: any = {}
CFrameMeta.__index = CFrameMeta
local function newCFrame(x: number, y: number, z: number, r: { number }?): any
	return setmetatable(
		{ Position = { X = x, Y = y, Z = z }, R = r or { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
		CFrameMeta
	)
end
CFrameMeta.__mul = function(a: any, b: any): any
	local ar, br, bp = a.R, b.R, b.Position
	local r = {}
	for row = 0, 2 do
		for col = 0, 2 do
			local sum = 0
			for k = 0, 2 do
				sum += ar[row * 3 + k + 1] * br[k * 3 + col + 1]
			end
			r[row * 3 + col + 1] = sum
		end
	end
	local function rotated(row: number): number
		return ar[row * 3 + 1] * bp.X + ar[row * 3 + 2] * bp.Y + ar[row * 3 + 3] * bp.Z
	end
	return newCFrame(a.Position.X + rotated(0), a.Position.Y + rotated(1), a.Position.Z + rotated(2), r)
end
local CFrame = {
	new = function(x: number?, y: number?, z: number?): any
		return newCFrame(x or 0, y or 0, z or 0)
	end,
	Angles = function(rx: number, ry: number, rz: number): any
		assert(rx == 0 and rz == 0, "FakeGame: CFrame.Angles only turns about Y")
		local c, s = math.cos(ry), math.sin(ry)
		return newCFrame(0, 0, 0, { c, 0, s, 0, 1, 0, -s, 0, c })
	end,
}

function FakeGame.cframe(x: number, y: number, z: number): any
	return newCFrame(x, y, z)
end

-- A part, folder or remote that records what was done to it. Parent is a plain field.
local function newInstance(world: any, className: string): any
	local instance: any = { ClassName = className, Name = className, Parent = nil, attributes = {} }
	function instance.SetAttribute(self: any, name: string, value: any)
		self.attributes[name] = value
	end
	function instance.GetAttribute(self: any, name: string): any
		return self.attributes[name]
	end
	function instance.Destroy(self: any)
		self.destroyed = true
	end
	function instance.PivotTo(self: any, cf: any)
		self.pivot = cf
	end
	if className == "RemoteEvent" then
		instance.OnServerEvent = signal(world)
		function instance.FireClient(_, player: any, payload: any)
			if world.fireThrows then
				error("FireClient failed")
			end
			table.insert(world.synced, { userId = player.UserId, payload = payload })
		end
	end
	table.insert(world.instances, instance)
	return instance
end

local function alive(instance: any): boolean
	local at = instance
	while at ~= nil do
		if rawget(at, "destroyed") then
			return false
		end
		at = rawget(at, "Parent")
	end
	return true
end

function FakeGame.new(options: Options?): any
	local opts: Options = options or {}
	local world: any = {
		records = opts.records or {},
		players = {},
		warnings = {},
		prints = {},
		synced = {},
		instances = {},
		plots = {},
		fireThrows = false,
		guids = 0,
	}
	world.clock = FakeClock.new(opts.start or 0)
	world.sched = FakeScheduler.new(world.clock)
	world.ds = FakeDataStore.new(world.records)
	world.errors = {} -- errors thrown in spawned threads and signal handlers, which Roblox only logs

	-- Runs fn(...) in a new thread on the scheduler, logging an error instead of raising it.
	function world.spawnLogged(self: any, fn: (...any) -> (), ...: any)
		local args = table.pack(...)
		self.sched:spawn(function()
			local ok, err = pcall(fn, table.unpack(args, 1, args.n))
			if not ok then
				table.insert(self.errors, tostring(err))
			end
		end)
	end

	local Players: any
	Players = strict("Players", {
		PlayerAdded = signal(world),
		PlayerRemoving = signal(world),
		GetPlayers = function()
			local list = {}
			for _, player in world.players do
				table.insert(list, player)
			end
			return list
		end,
		GetPlayerByUserId = function(_, userId: number)
			return world.players[userId]
		end,
	})

	local config = opts.config or SHARED.Config
	local sharedFolder = strict("Paddock", {
		WaitForChild = function(_, name: string)
			local value = if name == "Config" then config else SHARED[name]
			assert(value ~= nil, `FakeGame: no shared module {name}`)
			return moduleRef(name, value)
		end,
	})

	local services: { [string]: any } = {
		CollectionService = strict("CollectionService", {
			GetTagged = function(_, tag: string)
				assert(tag == "PaddockPlot", `FakeGame: unexpected tag {tag}`)
				return table.clone(world.plots)
			end,
		}),
		DataStoreService = strict("DataStoreService", {
			GetDataStore = function()
				return world.ds
			end,
			GetRequestBudgetForRequestType = function()
				return 100
			end,
		}),
		HttpService = strict("HttpService", {
			GenerateGUID = function()
				world.guids += 1
				return `guid-{world.guids}`
			end,
		}),
		Players = Players,
		ReplicatedStorage = strict("ReplicatedStorage", {
			WaitForChild = function(_, name: string)
				assert(name == "Paddock", name)
				if opts.blockShared then
					world.sched:wait(math.huge)
				end
				return sharedFolder
			end,
			FindFirstChild = function(_, _name: string)
				return nil -- no PaddockPieces folder, so every piece is a plain box
			end,
		}),
		RunService = strict("RunService", {
			IsStudio = function()
				return false -- so the script uses the data store it is given, which is the fake
			end,
		}),
		ServerStorage = strict("ServerStorage", {
			GetAttribute = function()
				return nil
			end,
		}),
		Workspace = strict("Workspace", {}),
	}

	local function folder(prefix: string, modules: { [string]: any }): any
		local out = {}
		for name, value in modules do
			out[name] = moduleRef(prefix .. name, value)
		end
		return out
	end

	local script: any = { Data = folder("Data.", DATA) }
	for name, value in SERVER do
		script[name] = moduleRef(name, value)
	end

	local env: any = {
		game = strict("game", {
			JobId = "JOB",
			GetService = function(_, name: string)
				local service = services[name]
				assert(service ~= nil, `FakeGame: service {name} is not modelled`)
				return service
			end,
			BindToClose = function(_, fn: () -> ())
				world.onClose = fn
			end,
		}),
		script = script,
		require = function(ref: any): any
			assert(type(ref) == "table" and ref.__moduleName ~= nil, "FakeGame: require of a non-module")
			if opts.failRequire == ref.__moduleName then
				error(`{ref.__moduleName} failed to load`)
			end
			return ref.__module
		end,
		Instance = {
			new = function(className: string): any
				return newInstance(world, className)
			end,
		},
		CFrame = CFrame,
		Vector3 = {
			new = function(x: number, y: number, z: number): any
				return { X = x, Y = y, Z = z }
			end,
		},
		Color3 = {
			fromRGB = function(r: number, g: number, b: number): any
				return { R = r, G = g, B = b }
			end,
		},
		Enum = {
			DataStoreRequestType = { UpdateAsync = "UpdateAsync" },
		},
		task = {
			spawn = function(fn: any, ...: any)
				if type(fn) == "thread" then
					world.sched:spawn(fn)
					return
				end
				world:spawnLogged(fn, ...)
			end,
			wait = function(seconds: number?): number
				world.sched:wait(seconds or 0)
				return seconds or 0
			end,
		},
		os = {
			time = function(): number
				return math.floor(world.clock:now())
			end,
			clock = function(): number
				return world.clock:now()
			end,
		},
		warn = function(...: any)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(world.warnings, table.concat(parts, " "))
		end,
		print = function(...: any)
			table.insert(world.prints, table.concat({ ... }, " "))
		end,
	}

	-- Starts the script in its own thread, as Roblox does. `started` is true once it reaches the
	-- end, and `startError` holds anything it threw.
	function world.start(self: any)
		local chunk = luau.load(SOURCE, { debugName = "init.server", environment = env })
		self.sched:spawn(function()
			local ok, err = pcall(chunk)
			self.started = ok
			self.startError = if ok then nil else tostring(err)
		end)
		return self
	end

	function world.join(self: any, userId: number): any
		local player: any = { UserId = userId, Name = `player{userId}`, Parent = Players, attributes = {} }
		function player.Kick(p: any, message: string)
			p.kicked = message
		end
		self.players[userId] = player
		Players.PlayerAdded:fire(player)
		return player
	end

	-- PlayerRemoving fires while the player is still in Players; then they are gone.
	function world.leave(self: any, userId: number)
		local player = self.players[userId]
		Players.PlayerRemoving:fire(player)
		self.players[userId] = nil
		player.Parent = nil
	end

	function world.remote(self: any, name: string): any
		for _, instance in self.instances do
			if instance.Name == name and instance.ClassName == "RemoteEvent" then
				return instance
			end
		end
		return nil
	end

	-- A client firing the Request remote.
	function world.request(self: any, userId: number, ...: any)
		local remote = self:remote("Request")
		assert(remote ~= nil, "no Request remote")
		remote.OnServerEvent:fire(self.players[userId], ...)
	end

	-- A part tagged PaddockPlot. Must be added before start().
	function world.addPlot(self: any, index: any, size: any, cframe: any?): any
		local plot: any = {
			Name = `Plot{tostring(index)}`,
			Size = { X = size[1], Y = size[2], Z = size[3] },
			CFrame = cframe or newCFrame(0, 0, 0),
			attributes = { PlotIndex = index },
			IsA = function(_, className: string): boolean
				return className == "BasePart"
			end,
			GetAttribute = function(p: any, name: string): any
				return p.attributes[name]
			end,
		}
		table.insert(self.plots, plot)
		return plot
	end

	-- The piece models on a plot that have not been destroyed, by uid.
	function world.models(self: any, plotIndex: number): { [number]: any }
		local out = {}
		for _, instance in self.instances do
			local parent = instance.Parent
			if
				instance.ClassName == "Part"
				and parent ~= nil
				and parent.Name == "Plot" .. plotIndex
				and alive(instance)
			then
				out[instance:GetAttribute("PaddockUid")] = instance
			end
		end
		return out
	end

	-- The latest Sync sent to a player.
	function world.lastSync(self: any, userId: number): any
		for i = #self.synced, 1, -1 do
			if self.synced[i].userId == userId then
				return self.synced[i].payload
			end
		end
		return nil
	end

	return world
end

return FakeGame
