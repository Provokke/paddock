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

type Rig = { handlers: any, calls: { string }, syncs: { number }, logs: { string }, clock: any }

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
	local r: Rig = { calls = {}, syncs = {}, logs = {}, clock = clock, handlers = nil }
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
		log = function(message: string)
			table.insert(r.logs, message)
		end,
	})
	return r
end

-- A real Build over a Wallet whose onChange yields while `gate.armed` is set, so a call can be
-- parked inside the wallet and another call made in the gap.
local function yieldingBuild(coins: number, gate: { armed: boolean }): (any, any, { coins: number })
	local defs = Deep.copy(Config.Placeables)
	local layout = Layout.new(10, 8, defs)
	local data = { coins = coins }
	local wallet = Wallet.new(data, function()
		if gate.armed and coroutine.isyieldable() then
			coroutine.yield()
		end
	end)
	local build = Build.new({
		layout = layout,
		wallet = wallet,
		defs = defs,
		sellRefund = Config.SellRefund,
		undoDepth = Config.UndoDepth,
		undoSeconds = Config.UndoSeconds,
		now = function()
			return 0
		end,
	})
	return build, layout, data
end

-- The kinds in a build's undo history, oldest first, with the uid each one is for.
local function historyOf(build: any): string
	local out = {}
	for _, entry in build.history do
		table.insert(out, `{entry.kind} {entry.uid}`)
	end
	return table.concat(out, ", ")
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
		name = "a build that throws logs one line with the player, the action and the error",
		run = function()
			local calls: { string } = {}
			local r = rig(fakeBuild(calls, true))
			r.handlers:handle(7, "sell", 3)
			assert(#r.logs == 1, `{#r.logs} lines`)
			local line = r.logs[1]
			for _, part in { "7", "sell", "build broke" } do
				assert(string.find(line, part, 1, true), `{part} missing from: {line}`)
			end
			assert(#r.syncs == 1, "still synced")
			-- control: a call the rules refuse is an ordinary answer and logs nothing
			local build = yieldingBuild(0, { armed = false })
			local quiet = rig(build)
			quiet.handlers:handle(1, "place", "shed", 0, 0, 0)
			assert(build.deps.layout:pieces()[1] == nil, "refused as cant_afford")
			assert(#quiet.logs == 0, quiet.logs[1])
			assert(quiet.handlers.dropped == 0, "a rule refusal is not counted as dropped")
		end,
	},
	{
		name = "a call while the same player's last call waits on the wallet is dropped and counted",
		run = function()
			local gate = { armed = true }
			local build, layout, data = yieldingBuild(500, gate)
			local r = rig(build)
			local first = coroutine.create(function()
				r.handlers:handle(1, "place", "shed", 0, 0, 0)
			end)
			assert(coroutine.resume(first))
			assert(coroutine.status(first) == "suspended", "negative control: the wallet must yield")
			assert(r.handlers:busy(1) and not r.handlers:busy(2))
			gate.armed = false
			r.handlers:handle(1, "place", "fence", 5, 5, 0)
			r.handlers:handle(1, "undo")
			assert(r.handlers.dropped == 2, `{r.handlers.dropped} dropped`)
			assert(#r.syncs == 0, "a dropped call is not synced")
			assert(#layout:pieces() == 1 and data.coins == 380)
			assert(coroutine.resume(first))
			assert(coroutine.status(first) == "dead" and not r.handlers:busy(1))
			assert(#r.syncs == 1)
			-- control: once it has finished, the next call goes through
			r.handlers:handle(1, "place", "fence", 5, 5, 0)
			assert(#layout:pieces() == 2 and data.coins == 370 and r.handlers.dropped == 2)
		end,
	},
	{
		name = "the busy guard keeps undo history in order when a refused undo waited on the wallet",
		run = function()
			-- History is place fence, place shed, sell shed. The undo of the sell waits on the
			-- wallet and is then refused, so its entry goes back on top. A place sent in the gap
			-- must not end up below it.
			local gate = { armed = false }
			local build, layout, data = yieldingBuild(500, gate)
			local r = rig(build)
			r.handlers:handle(1, "place", "fence", 0, 0, 0)
			r.handlers:handle(1, "place", "shed", 4, 0, 0)
			local shed = layout:pieces()[2]
			r.handlers:handle(1, "sell", shed.uid)
			local before = historyOf(build)
			data.coins = 400
			-- The charge back of 60 yields, then finds the balance gone and is refused.
			local real = build.deps.wallet.charge
			build.deps.wallet.charge = function(self: any, amount: number, reason: string): boolean
				if reason == "undo sell" then
					coroutine.yield()
					return false
				end
				return real(self, amount, reason)
			end
			local undo = coroutine.create(function()
				r.handlers:handle(1, "undo")
			end)
			assert(coroutine.resume(undo))
			assert(coroutine.status(undo) == "suspended", "negative control: the undo must be parked")
			r.handlers:handle(1, "place", "hay_bale", 9, 7, 0)
			assert(coroutine.resume(undo))
			assert(historyOf(build) == before, `{historyOf(build)} vs {before}`)
			assert(#layout:pieces() == 1 and data.coins == 400, "the refused undo changed nothing")
			-- control: without the guard the same place lands in the gap, under the re-pushed entry
			local open = yieldingBuild(500, gate)
			open:place("fence", 0, 0, 0)
			local s = open:place("shed", 4, 0, 0)
			open:sell(s.uid)
			open.deps.wallet.charge = build.deps.wallet.charge
			local bare = coroutine.create(function()
				open:undo()
			end)
			assert(coroutine.resume(bare))
			open:place("hay_bale", 9, 7, 0)
			assert(coroutine.resume(bare))
			local entries = open.history
			assert(entries[#entries].kind == "sell", "the re-pushed sell sits above the newer place")
			assert(entries[#entries - 1].kind == "place", historyOf(open))
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
