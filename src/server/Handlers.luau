--!strict
-- What the client may ask the server for. A factory: everything arrives as a dependency, so the
-- checks can be tested without remotes.
--
-- Clients send intent only: an action name, an item id, cell coordinates, a rotation or a uid.
-- Every call is checked with Validate and then the per-player rate limiter before anything else.
-- A call that fails either, arrives while the same player's last call is still running, or comes
-- from a player with no build, is dropped and counted. A call the rules refuse (cant_afford,
-- overlap, limit and so on) is not counted, as that is an ordinary answer. Nothing is sent back
-- about why. The client learns the result from the next Sync, which carries the real state.
--
-- Busy guard: a build call can yield inside a wallet. While it does, any other call from that
-- player is dropped, so one player's calls never interleave. The entry script also waits on
-- `busy` before it releases a session on leave or shutdown.
local Handlers = {}
Handlers.__index = Handlers

export type Deps = {
	validate: any, -- the Validate module
	limiter: any, -- a RateLimiter, keyed by UserId
	buildFor: (userId: number) -> any?, -- the player's Build, or nil when they can't build
	sync: (userId: number) -> (), -- sends one player their current state
	log: (message: string) -> (), -- one line per build call that threw
}

export type Handlers = typeof(setmetatable(
	{} :: { deps: Deps, dropped: number, running: { [number]: boolean } },
	Handlers
))

local ACTIONS: { [string]: boolean } = { place = true, move = true, sell = true, undo = true }
local MAX_ID = 32 -- ConfigCheck holds piece ids to the same length
local MAX_CELL = 1000
local MAX_UID = 2 ^ 31

function Handlers.new(deps: Deps): Handlers
	return setmetatable({ deps = deps, dropped = 0, running = {} }, Handlers)
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

-- Whether a build call for this player is still running (it is waiting on the wallet).
function Handlers.busy(self: Handlers, userId: number): boolean
	return self.running[userId] == true
end

-- One call from a client. Returns nothing and never throws.
function Handlers.handle(self: Handlers, userId: number, action: any, a: any, b: any, c: any, d: any)
	local deps = self.deps
	local ok = pcall(function()
		if not valid(deps.validate, action, a, b, c, d) or not deps.limiter:take(userId) then
			self.dropped += 1
			return
		end
		if self.running[userId] then
			self.dropped += 1
			return
		end
		local build = deps.buildFor(userId)
		if build == nil then
			self.dropped += 1
			return
		end
		-- The result is not sent back; the Sync that follows carries it. A build that throws is
		-- counted and logged, and the player is still synced, as its state may have changed part
		-- way.
		self.running[userId] = true
		local done, err = pcall(function()
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
		self.running[userId] = nil
		if not done then
			self.dropped += 1
			pcall(deps.log, `build call failed for {userId} ({action}): {tostring(err)}`)
		end
		deps.sync(userId)
	end)
	if not ok then
		self.dropped += 1
	end
end

return Handlers
