--!strict
-- What a client can and can't make the server do.
local Build = require("../../src/server/Build")
local Config = require("../../src/shared/Config")
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local Handlers = require("../../src/server/Handlers")
local Layout = require("../../src/shared/Layout")
local RateLimiter = require("../../src/shared/RateLimiter")
local Validate = require("../../src/shared/Validate")
local Wallet = require("../../src/server/Wallet")

type Rig = { handlers: any, calls: { string }, syncs: { number }, clock: any }

-- A build that records what it was asked and can be told to throw.
local function fakeBuild(calls: { string }, throws: boolean?): any
	local function record(name: string): (...any) -> ()
		return function(_self: any, ...: any)
			if throws then
				error("build broke")
			end
			local parts = { name }
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(calls, table.concat(parts, " "))
		end
	end
	return { place = record("place"), move = record("move"), sell = record("sell"), undo = record("undo") }
end

-- User 99 has no build.
local function rig(build: any?, burst: number?): Rig
	local clock = FakeClock.new(0)
	local r: Rig = { calls = {}, syncs = {}, clock = clock, handlers = nil }
	local b = build
	if b == nil then
		b = fakeBuild(r.calls)
	end
	r.handlers = Handlers.new({
		validate = Validate,
		limiter = RateLimiter.new(burst or 100, 1, function()
			return clock:now()
		end),
		buildFor = function(userId: number): any
			if userId == 99 then
				return nil
			end
			return b
		end,
		sync = function(userId: number)
			table.insert(r.syncs, userId)
		end,
	})
	return r
end

local function dropped(r: Rig, ...: any)
	r.handlers:handle(1, ...)
	assert(#r.calls == 0, `a build call went through: {r.calls[1]}`)
	assert(#r.syncs == 0, "a dropped call is not synced")
end

return {
	{
		name = "bad place arguments are dropped with no build call and no sync",
		run = function()
			local nan = 0 / 0
			local bad: { { any } } = {
				{ "place", "shed", nan, 0, 0 },
				{ "place", "shed", 0, math.huge, 0 },
				{ "place", "shed", -math.huge, 0, 0 },
				{ "place", "shed", 1.5, 0, 0 },
				{ "place", "shed", 0, 1.5, 0 },
				{ "place", "shed", 1001, 0, 0 },
				{ "place", "shed", 0, -1001, 0 },
				{ "place", string.rep("a", 33), 0, 0, 0 },
				{ "place", "", 0, 0, 0 },
				{ "place", 5, 0, 0, 0 },
				{ "place", "shed", 0, 0, 4 },
				{ "place", "shed", 0, 0, -1 },
				{ "place", "shed", 0, 0, 1.5 },
				{ "place", "shed", "0", 0, 0 },
			}
			local r = rig()
			for _, args in bad do
				dropped(r, table.unpack(args, 1, 5))
			end
			dropped(r, "place", "shed", 0, 0) -- no rotation
			dropped(r, "place", nil, 0, 0, 0)
			assert(r.handlers.dropped == #bad + 2, `{r.handlers.dropped} dropped`)
		end,
	},
	{
		name = "bad move, sell and unknown-action arguments are dropped",
		run = function()
			local r = rig()
			dropped(r, "move", 0, 1, 1, 0)
			dropped(r, "move", "7", 1, 1, 0)
			dropped(r, "move", 1.5, 1, 1, 0)
			dropped(r, "move", 1, 1, 1, 4)
			dropped(r, "move", 1, 1.5, 1, 0)
			dropped(r, "move", 1, 1, 0 / 0, 0)
			dropped(r, "sell", 0)
			dropped(r, "sell", "3")
			dropped(r, "sell", 0 / 0)
			dropped(r, "sell", math.huge)
			dropped(r, "sell", -2)
			dropped(r, "sell", {})
			dropped(r, "launch", 1)
			dropped(r, 5, 1)
			dropped(r, nil)
			dropped(r, { "place" })
		end,
	},
	{
		name = "good input calls the build once and syncs once",
		run = function()
			local r = rig()
			r.handlers:handle(1, "place", "shed", 2, 3, 1)
			assert(r.calls[1] == "place shed 2 3 1" and #r.calls == 1, tostring(r.calls[1]))
			assert(#r.syncs == 1 and r.syncs[1] == 1)
			r.handlers:handle(1, "move", 4, -5, 6, 3)
			assert(r.calls[2] == "move 4 -5 6 3" and #r.calls == 2 and #r.syncs == 2)
			r.handlers:handle(1, "sell", 4)
			assert(r.calls[3] == "sell 4" and #r.calls == 3 and #r.syncs == 3)
			r.handlers:handle(1, "undo", "ignored", 1, 2)
			assert(r.calls[4] == "undo" and #r.calls == 4 and #r.syncs == 4, tostring(r.calls[4]))
			assert(r.handlers.dropped == 0)
		end,
	},
	{
		name = "the edges of the ranges are accepted",
		run = function()
			local r = rig()
			r.handlers:handle(1, "place", string.rep("a", 32), -1000, 1000, 3)
			r.handlers:handle(1, "move", 1, 1000, -1000, 0)
			assert(#r.calls == 2 and #r.syncs == 2, `{#r.calls} calls`)
		end,
	},
	{
		name = "calls over the burst limit are dropped, and refill over time",
		run = function()
			local r = rig(nil, 3)
			for _ = 1, 5 do
				r.handlers:handle(1, "undo")
			end
			assert(#r.calls == 3 and #r.syncs == 3, `{#r.calls} calls`)
			assert(r.handlers.dropped == 2)
			-- another player has their own allowance
			r.handlers:handle(2, "undo")
			assert(#r.calls == 4)
			r.clock:advance(2)
			r.handlers:handle(1, "undo")
			assert(#r.calls == 5, "refilled")
		end,
	},
	{
		name = "a player with no build has the call dropped and no sync",
		run = function()
			local r = rig()
			r.handlers:handle(99, "place", "shed", 0, 0, 0)
			r.handlers:handle(99, "undo")
			assert(#r.calls == 0 and #r.syncs == 0 and r.handlers.dropped == 2)
		end,
	},
	{
		name = "a build that errors does not escape handle",
		run = function()
			local calls: { string } = {}
			local r = rig(fakeBuild(calls, true))
			local ok, err = pcall(function()
				r.handlers:handle(1, "place", "shed", 0, 0, 0)
				r.handlers:handle(1, "sell", 1)
			end)
			assert(ok, tostring(err))
			assert(r.handlers.dropped == 2, "counted")
		end,
	},
	{
		name = "two place requests for sheds at a balance of 130 leave one shed and 10 coins",
		run = function()
			local defs = Deep.copy(Config.Placeables)
			local layout = Layout.new(10, 8, defs)
			local data = { coins = 130 }
			local wallet = Wallet.new(data)
			local clock = FakeClock.new(1000)
			local build = Build.new({
				layout = layout,
				wallet = wallet,
				defs = defs,
				sellRefund = Config.SellRefund,
				undoDepth = Config.UndoDepth,
				undoSeconds = Config.UndoSeconds,
				now = function()
					return clock:now()
				end,
			})
			local r = rig(build)
			r.handlers:handle(1, "place", "shed", 0, 0, 0)
			r.handlers:handle(1, "place", "shed", 5, 0, 0)
			local pieces = layout:pieces()
			assert(#pieces == 1 and pieces[1].id == "shed", `{#pieces} pieces`)
			assert(data.coins == 10, `{data.coins} coins`)
			assert(#r.syncs == 2, "the refused request is synced too, so the client sees the truth")
		end,
	},
}
