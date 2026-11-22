--!strict
-- Build against wallets and layouts that misbehave: a wallet that yields mid-call (so a second
-- call can run in the gap), a wallet that refuses, and a layout whose place fails late.
local Config = require("../../src/shared/Config")
local Deep = require("../fakes/Deep")
local Layout = require("../../src/shared/Layout")
local Build = require("../../src/server/Build")

type Fake = {
	coins: number,
	yields: number,
	armed: boolean, -- only yields while a test has armed it
	log: { string },
	refuseCredit: boolean,
	refuseCharge: boolean,
	where: string, -- "before" or "after" the balance changes
	balance: (any) -> number,
	charge: (any, number, string) -> boolean,
	credit: (any, number, string) -> boolean,
}

local function maybeYield(self: Fake)
	if self.armed and coroutine.isyieldable() then
		self.yields += 1
		coroutine.yield()
	end
end

-- A wallet that yields inside charge and credit. `where` picks whether it yields before or after
-- it changes the balance; both are tried.
local function fakeWallet(coins: number, where: string): Fake
	local w: Fake = {
		coins = coins,
		yields = 0,
		armed = false,
		log = {},
		refuseCredit = false,
		refuseCharge = false,
		where = where,
		balance = function(self)
			return (self :: any).coins
		end,
		charge = function(self, amount, reason)
			local f = self :: any
			table.insert(f.log, `charge {amount} {reason}`)
			if f.where == "before" then
				maybeYield(f)
			end
			local ok = not f.refuseCharge and amount <= f.coins
			if ok then
				f.coins -= amount
			end
			if f.where == "after" then
				maybeYield(f)
			end
			return ok
		end,
		credit = function(self, amount, reason)
			local f = self :: any
			table.insert(f.log, `credit {amount} {reason}`)
			if f.where == "before" then
				maybeYield(f)
			end
			local ok = not f.refuseCredit
			if ok then
				f.coins += amount
			end
			if f.where == "after" then
				maybeYield(f)
			end
			return ok
		end,
	}
	return w
end

type Rig = { build: any, layout: any, wallet: Fake, defs: any }

local function rig(coins: number, where: string): Rig
	local defs = Deep.copy(Config.Placeables)
	local layout = Layout.new(10, 8, defs)
	local wallet = fakeWallet(coins, where)
	local build = Build.new({
		layout = layout,
		wallet = wallet :: any,
		defs = defs,
		sellRefund = 0.5,
		undoDepth = 5,
		undoSeconds = 30,
		now = function()
			return 0
		end,
	})
	return { build = build, layout = layout, wallet = wallet, defs = defs }
end

local function state(r: Rig): any
	return Deep.copy({ coins = r.wallet.coins, pieces = r.layout:pieces() })
end

-- Starts every function as its own coroutine, so each runs to its first yield, then finishes them
-- in `order`. Returns each one's results. Counts as a control that at least one really yielded.
local function interleave(r: Rig, fns: { () -> (any, any) }, order: { number }): { { any } }
	local before = r.wallet.yields
	r.wallet.armed = true
	local threads = {}
	for i, fn in fns do
		threads[i] = coroutine.create(fn)
		local ok, err = coroutine.resume(threads[i])
		assert(ok, tostring(err))
	end
	local results = {}
	for _, i in order do
		local thread = threads[i]
		while coroutine.status(thread) ~= "dead" do
			local ok, a, b = coroutine.resume(thread)
			assert(ok, tostring(a))
			if coroutine.status(thread) == "dead" then
				results[i] = { a, b }
			end
		end
	end
	r.wallet.armed = false
	assert(r.wallet.yields > before, "negative control: the wallet never yielded, so nothing was tested")
	return results
end

local orders: { { number } } = { { 1, 2 }, { 2, 1 } }
local wheres: { string } = { "before", "after" }

-- Runs `scenario` for every yield position and resume order.
local function eachCase(scenario: (where: string, order: { number }) -> ())
	for _, where in wheres do
		for _, order in orders do
			scenario(where, order)
		end
	end
end

local function placed(r: Rig, id: string, x: number, z: number): any
	local piece, why = r.build:place(id, x, z, 0)
	assert(piece ~= nil, tostring(why))
	return piece
end

return {
	{
		name = "yield: selling the same uid twice pays once",
		run = function()
			eachCase(function(where, order)
				local r = rig(500, where)
				local shed = placed(r, "shed", 0, 0)
				local serial = rig(500, where)
				local s = placed(serial, "shed", 0, 0)
				serial.build:sell(s.uid)
				local res = interleave(r, {
					function()
						return r.build:sell(shed.uid)
					end,
					function()
						return r.build:sell(shed.uid)
					end,
				}, order)
				assert(Deep.equal(state(r), state(serial)), `{where} {order[1]}: not the serial state`)
				assert(r.wallet.coins == 440 and #r.layout:pieces() == 0)
				local paid = 0
				for _, one in res do
					if one[1] ~= nil then
						paid += 1
					else
						assert(one[2] == "no_piece")
					end
				end
				assert(paid == 1, "exactly one sale pays")
			end)
		end,
	},
	{
		name = "yield: two undos after a place each undo their own entry once",
		run = function()
			eachCase(function(where, order)
				local r = rig(500, where)
				placed(r, "fence", 0, 0)
				placed(r, "shed", 4, 0)
				local serial = rig(500, where)
				placed(serial, "fence", 0, 0)
				placed(serial, "shed", 4, 0)
				serial.build:undo()
				serial.build:undo()
				interleave(r, {
					function()
						return r.build:undo()
					end,
					function()
						return r.build:undo()
					end,
				}, order)
				assert(Deep.equal(state(r), state(serial)), `{where} {order[1]}: not the serial state`)
				assert(r.wallet.coins == 500 and #r.layout:pieces() == 0)
			end)
		end,
	},
	{
		name = "yield: undo of one place called twice refunds once",
		run = function()
			eachCase(function(where, order)
				local r = rig(500, where)
				placed(r, "shed", 0, 0)
				interleave(r, {
					function()
						return r.build:undo()
					end,
					function()
						return r.build:undo()
					end,
				}, order)
				assert(r.wallet.coins == 500, `{where}: balance {r.wallet.coins}`)
				assert(#r.layout:pieces() == 0)
			end)
		end,
	},
	{
		name = "yield: undo twice after a sell never mints Coins",
		run = function()
			-- History is place, sell. Serially the second undo would also remove the shed. In the
			-- gap the older place entry is reached while the shed is still gone, so it is dropped as
			-- no_piece. The ledger must balance either way: Coins plus the shed's 120 stay at 500.
			eachCase(function(where, order)
				local r = rig(500, where)
				local shed = placed(r, "shed", 0, 0)
				r.build:sell(shed.uid)
				assert(r.wallet.coins == 440)
				interleave(r, {
					function()
						return r.build:undo()
					end,
					function()
						return r.build:undo()
					end,
				}, order)
				local held = #r.layout:pieces() * 120
				assert(r.wallet.coins + held == 500, `{where}: coins {r.wallet.coins}, shed held {held}`)
				assert(r.wallet.coins <= 500)
			end)
		end,
	},
	{
		name = "yield: undo sell called twice charges back once",
		run = function()
			eachCase(function(where, order)
				local r = rig(500, where)
				local shed = placed(r, "shed", 0, 0)
				r.build:sell(shed.uid)
				-- Drop the older place entry so only the sell can be undone.
				r.build.history = { r.build.history[2] }
				interleave(r, {
					function()
						return r.build:undo()
					end,
					function()
						return r.build:undo()
					end,
				}, order)
				assert(r.wallet.coins == 380, `{where}: balance {r.wallet.coins}`)
				assert(r.layout:get(shed.uid) ~= nil)
				assert(#r.layout:pieces() == 1)
			end)
		end,
	},
	{
		name = "yield: two places of a shed with Coins for one",
		run = function()
			eachCase(function(where, order)
				local r = rig(130, where)
				local serial = rig(130, where)
				placed(serial, "shed", 0, 0)
				serial.build:place("shed", 4, 0, 0)
				local res = interleave(r, {
					function()
						return r.build:place("shed", 0, 0, 0)
					end,
					function()
						return r.build:place("shed", 4, 0, 0)
					end,
				}, order)
				assert(r.wallet.coins == 10 and #r.layout:pieces() == 1, `{where}: coins {r.wallet.coins}`)
				local failed = 0
				for _, one in res do
					if one[1] == nil then
						failed += 1
						assert(one[2] == "cant_afford")
					end
				end
				assert(failed == 1)
				assert(serial.wallet.coins == 10)
			end)
		end,
	},
	{
		name = "yield: two places into the same cells pay once, the loser is credited back",
		run = function()
			eachCase(function(where, order)
				local r = rig(500, where)
				local res = interleave(r, {
					function()
						return r.build:place("shed", 0, 0, 0)
					end,
					function()
						return r.build:place("shed", 0, 0, 0)
					end,
				}, order)
				assert(r.wallet.coins == 380, `{where}: coins {r.wallet.coins}`)
				assert(#r.layout:pieces() == 1)
				local lost = 0
				for _, one in res do
					if one[1] == nil then
						lost += 1
						assert(one[2] == "overlap")
					end
				end
				assert(lost == 1)
			end)
		end,
	},
	{
		name = "negative control: the same two sells with a wallet that never yields also pay once",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 0, 0)
			assert(r.build:sell(shed.uid) == 60)
			local refund, why = r.build:sell(shed.uid)
			assert(refund == nil and why == "no_piece")
			assert(r.wallet.coins == 440)
			assert(r.wallet.yields == 0, "outside a coroutine the fake must not yield")
		end,
	},
	{
		name = "a refused credit on sell rolls the sale back with the same uid",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 2, 1)
			r.wallet.refuseCredit = true
			local before = state(r)
			local refund, why = r.build:sell(shed.uid)
			assert(refund == nil and why == "wallet_refused")
			assert(Deep.equal(before, state(r)))
			r.wallet.refuseCredit = false
			assert(r.build:undo() == "place", "no sell entry was pushed")
		end,
	},
	{
		name = "a refused credit on undo place restores the piece and the entry",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 2, 1)
			r.wallet.refuseCredit = true
			local before = state(r)
			local kind, why = r.build:undo()
			assert(kind == nil and why == "wallet_refused")
			assert(Deep.equal(before, state(r)))
			assert(r.layout:get(shed.uid) ~= nil)
			r.wallet.refuseCredit = false
			assert(r.build:undo() == "place", "the entry must still be undoable")
			assert(r.wallet.coins == 500)
		end,
	},
	{
		name = "undo sell with the cells taken never touches the wallet",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 0, 0)
			r.build:sell(shed.uid)
			assert(r.layout:place("shed", 0, 0, 0))
			local calls = #r.wallet.log
			local kind, why = r.build:undo()
			assert(kind == nil and why == "overlap")
			assert(#r.wallet.log == calls, "no charge and credit-back pair when the cells are taken")
		end,
	},
	{
		name = "undo sell refused with uid_taken when the uid is live again",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 0, 0)
			r.build:sell(shed.uid)
			r.layout:placeWithUid(shed.uid, "fence", 6, 6, 0)
			local before = state(r)
			local kind, why = r.build:undo()
			assert(kind == nil and why == "uid_taken")
			assert(Deep.equal(before, state(r)))
		end,
	},
	{
		name = "undo sell charge refused: entry kept, nothing changed",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 0, 0)
			r.build:sell(shed.uid)
			r.wallet.refuseCharge = true
			local before = state(r)
			local kind, why = r.build:undo()
			assert(kind == nil and why == "cant_afford")
			assert(Deep.equal(before, state(r)))
			r.wallet.refuseCharge = false
			assert(r.build:undo() == "sell", "the entry stays undoable")
		end,
	},
	{
		name = "place credits back when the layout place fails after canPlace passed",
		run = function()
			local r = rig(500, "after")
			r.layout.place = function()
				return nil, "overlap"
			end
			local before = state(r)
			local piece, why = r.build:place("shed", 0, 0, 0)
			assert(piece == nil and why == "overlap")
			assert(Deep.equal(before, state(r)))
			assert(r.wallet.log[1] == "charge 120 place shed")
			assert(r.wallet.log[2] == "credit 120 place failed shed")
			local kind, nothing = r.build:undo()
			assert(kind == nil and nothing == "nothing", "a failed place leaves no history")
		end,
	},
	{
		name = "a refused credit-back raises an error naming the amount",
		run = function()
			local r = rig(500, "after")
			r.layout.place = function()
				return nil, "overlap"
			end
			r.wallet.refuseCredit = true
			local ok, err = pcall(function()
				r.build:place("shed", 0, 0, 0)
			end)
			assert(not ok, "a refused credit-back must not be silent")
			assert(string.find(tostring(err), "120", 1, true), tostring(err))
			assert(string.find(tostring(err), "place failed shed", 1, true), tostring(err))
		end,
	},
	{
		name = "undo sell raises when the credit-back after a late place failure is refused",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 0, 0)
			r.build:sell(shed.uid)
			r.layout.placeWithUid = function()
				return nil, "overlap"
			end
			r.wallet.refuseCredit = true
			local ok, err = pcall(function()
				r.build:undo()
			end)
			assert(not ok)
			assert(string.find(tostring(err), "60", 1, true), tostring(err))
		end,
	},
	{
		name = "undo sell credits back and keeps the entry when the layout place fails late",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 0, 0)
			r.build:sell(shed.uid)
			local real = r.layout.placeWithUid
			r.layout.placeWithUid = function()
				return nil, "overlap"
			end
			local before = state(r)
			local kind, why = r.build:undo()
			assert(kind == nil and why == "overlap")
			assert(Deep.equal(before, state(r)))
			r.layout.placeWithUid = real
			assert(r.build:undo() == "sell")
		end,
	},
	{
		name = "place with a def missing from Build's defs is unknown_item",
		run = function()
			local r = rig(500, "after")
			r.build.deps.defs = { fence = r.defs.fence }
			local before = state(r)
			local piece, why = r.build:place("shed", 0, 0, 0)
			assert(piece == nil and why == "unknown_item")
			assert(Deep.equal(before, state(r)))
			assert(#r.wallet.log == 0, "no charge for an item Build cannot price")
		end,
	},
	{
		name = "Build.new rejects bad settings",
		run = function()
			local function try(sellRefund: any, undoDepth: any, undoSeconds: any): boolean
				local defs = Deep.copy(Config.Placeables)
				local ok = pcall(function()
					Build.new({
						layout = Layout.new(10, 8, defs) :: any,
						wallet = fakeWallet(0, "after") :: any,
						defs = defs,
						sellRefund = sellRefund,
						undoDepth = undoDepth,
						undoSeconds = undoSeconds,
						now = function()
							return 0
						end,
					})
				end)
				return ok
			end
			assert(try(0.5, 3, 30), "good settings must work")
			assert(try(0, 0, 0) and try(1, 10, 30))
			local badRefund: { any } = { -0.1, 1.1, 0 / 0, math.huge, -math.huge, "0.5" }
			for _, v in badRefund do
				assert(not try(v, 3, 30), `sellRefund {tostring(v)} should be rejected`)
			end
			local badDepth: { any } = { -1, 1.5, 0 / 0, math.huge, "3" }
			for _, v in badDepth do
				assert(not try(0.5, v, 30), `undoDepth {tostring(v)} should be rejected`)
			end
			local badSeconds: { any } = { -1, 0 / 0, math.huge, "30" }
			for _, v in badSeconds do
				assert(not try(0.5, 3, v), `undoSeconds {tostring(v)} should be rejected`)
			end
		end,
	},
	{
		name = "an undo whose piece is gone drops its entry, and the next undo reaches the older one",
		run = function()
			local r = rig(500, "after")
			placed(r, "fence", 0, 0)
			local hay = placed(r, "hay_bale", 5, 5)
			r.layout:remove(hay.uid)
			local before = state(r)
			local kind, why = r.build:undo()
			assert(kind == nil and why == "no_piece")
			assert(Deep.equal(before, state(r)))
			assert(r.build:undo() == "place", "the older entry must be reachable")
			assert(r.wallet.coins == 485)
			assert(#r.layout:pieces() == 0)
		end,
	},
	{
		name = "undo move whose piece is gone drops its entry",
		run = function()
			local r = rig(500, "after")
			local fence = placed(r, "fence", 0, 0)
			placed(r, "hay_bale", 5, 5)
			assert(r.build:move(fence.uid, 0, 2, 0))
			r.layout:remove(fence.uid)
			local kind, why = r.build:undo()
			assert(kind == nil and why == "no_piece")
			assert(r.build:undo() == "place", "this reaches the hay place entry")
			assert(r.wallet.coins == 490)
		end,
	},
}
