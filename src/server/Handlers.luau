--!strict
-- What the client may ask the server for. A factory: everything arrives as a dependency, so the
-- checks can be tested without remotes.
--
-- Clients send intent only: an action name, an item id, cell coordinates, a rotation or a uid.
-- Every call is checked with Validate and then the per-player rate limiter before anything else,
-- and a call that fails either is dropped and counted. Nothing is sent back about why. The client
-- learns the result from the next Sync, which carries the real state.
local Handlers = {}
Handlers.__index = Handlers

export type Deps = {
	validate: any, -- the Validate module
	limiter: any, -- a RateLimiter, keyed by UserId
	buildFor: (userId: number) -> any?, -- the player's Build, or nil when they can't build
	sync: (userId: number) -> (), -- sends one player their current state
}

export type Handlers = typeof(setmetatable({} :: { deps: Deps, dropped: number }, Handlers))

local ACTIONS: { [string]: boolean } = { place = true, move = true, sell = true, undo = true }
local MAX_ID = 32
local MAX_CELL = 1000
local MAX_UID = 2 ^ 31

function Handlers.new(deps: Deps): Handlers
	return setmetatable({ deps = deps, dropped = 0 }, Handlers)
end

-- Cell x, cell z and rotation.
local function validSpot(v: any, x: any, z: any, r: any): boolean
	return v.isInteger(x, -MAX_CELL, MAX_CELL)
		and v.isInteger(z, -MAX_CELL, MAX_CELL)
		and v.isInteger(r, 0, 3)
end

local function validUid(v: any, uid: any): boolean
	return v.isInteger(uid, 1, MAX_UID)
end

local function valid(v: any, action: any, a: any, b: any, c: any, d: any): boolean
	if not (v.isString(action, 16) and v.isOneOf(action, ACTIONS)) then
		return false
	end
	if action == "place" then
		return v.isString(a, MAX_ID) and #a >= 1 and validSpot(v, b, c, d)
	elseif action == "move" then
		return validUid(v, a) and validSpot(v, b, c, d)
	elseif action == "sell" then
		return validUid(v, a)
	end
	return true -- undo takes no arguments
end

-- One call from a client. Returns nothing and never throws.
function Handlers.handle(self: Handlers, userId: number, action: any, a: any, b: any, c: any, d: any)
	local deps = self.deps
	local ok = pcall(function()
		if not valid(deps.validate, action, a, b, c, d) or not deps.limiter:take(userId) then
			self.dropped += 1
			return
		end
		local build = deps.buildFor(userId)
		if build == nil then
			self.dropped += 1
			return
		end
		-- The result is not sent back; the Sync that follows carries it. A build that throws is
		-- counted, and the player is still synced, as its state may have changed part way.
		local done = pcall(function()
			if action == "place" then
				build:place(a, b, c, d)
			elseif action == "move" then
				build:move(a, b, c, d)
			elseif action == "sell" then
				build:sell(a)
			else
				build:undo()
			end
		end)
		if not done then
			self.dropped += 1
		end
		deps.sync(userId)
	end)
	if not ok then
		self.dropped += 1
	end
end

return Handlers
