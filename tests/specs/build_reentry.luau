--!strict
-- Build against wallets and layouts that misbehave: a wallet that yields mid-call (so a second
-- call can run in the gap), a wallet that refuses, and a layout whose place fails late. Also the
-- commit hook, which must run before every wallet call.
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

type Rig = { build: any, layout: any, wallet: Fake, defs: any, commits: { number } }

-- `commits` records how many pieces the layout held each time Build called commit.
local function rig(coins: number, where: string): Rig
	local defs = Deep.copy(Config.Placeables)
	local layout = Layout.new(10, 8, defs)
	local wallet = fakeWallet(coins, where)
	local commits: { number } = {}
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
		commit = function()
			table.insert(commits, #layout:pieces())
		end,
	})
	return { build = build, layout = layout, wallet = wallet, defs = defs, commits = commits }
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
	local results = {}
	for i, fn in fns do
		threads[i] = coroutine.create(fn)
		local ok, a, b = coroutine.resume(threads[i])
		assert(ok, tostring(a))
		-- A call that never reaches the wallet finishes here, on its first resume.
		if coroutine.status(threads[i]) == "dead" then
			results[i] = { a, b }
		end
	end
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
		name = "a layout place that fails after canPlace passed charges nothing",
		run = function()
			local r = rig(500, "after")
			r.layout.place = function()
				return nil, "overlap"
			end
			local before = state(r)
			local piece, why = r.build:place("shed", 0, 0, 0)
			assert(piece == nil and why == "overlap")
			assert(Deep.equal(before, state(r)))
			assert(#r.wallet.log == 0, "the piece comes before the charge, so the wallet is never called")
			local kind, nothing = r.build:undo()
			assert(kind == nil and nothing == "nothing", "a failed place leaves no history")
		end,
	},
	{
		name = "a refused credit on sell whose piece can't go back raises an error naming the uid",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 0, 0)
			r.layout.placeWithUid = function()
				return nil, "overlap"
			end
			r.wallet.refuseCredit = true
			local ok, err = pcall(function()
				r.build:sell(shed.uid)
			end)
			assert(not ok, "a sold piece that can't be put back must not be silent")
			assert(string.find(tostring(err), `sold piece {shed.uid}`, 1, true), tostring(err))
			-- control: when the piece can go back, the same refusal is an ordinary answer
			local c = rig(500, "after")
			local s = placed(c, "shed", 0, 0)
			c.wallet.refuseCredit = true
			local refund, why = c.build:sell(s.uid)
			assert(refund == nil and why == "wallet_refused")
		end,
	},
	{
		name = "undo sell keeps the entry and charges nothing when the layout place fails late",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 0, 0)
			r.build:sell(shed.uid)
			local real = r.layout.placeWithUid
			r.layout.placeWithUid = function()
				return nil, "overlap"
			end
			local before = state(r)
			local calls = #r.wallet.log
			local kind, why = r.build:undo()
			assert(kind == nil and why == "overlap")
			assert(Deep.equal(before, state(r)))
			assert(#r.wallet.log == calls, "the piece comes before the charge, so the wallet is never called")
			r.layout.placeWithUid = real
			assert(r.build:undo() == "sell")
		end,
	},
	{
		name = "undo sell with a refused charge takes the piece off again and keeps the entry",
		run = function()
			local r = rig(500, "after")
			local shed = placed(r, "shed", 0, 0)
			r.build:sell(shed.uid)
			r.wallet.refuseCharge = true
			local before = state(r)
			local kind, why = r.build:undo()
			assert(kind == nil and why == "cant_afford")
			assert(Deep.equal(before, state(r)))
			assert(r.commits[#r.commits] == 0, "the rollback was committed too")
			r.wallet.refuseCharge = false
			assert(r.build:undo() == "sell", "the entry stays undoable")
		end,
	},
	{
		name = "yield: a piece waiting on its charge can't be sold, moved or undone",
		run = function()
			for _, where in wheres do
				local r = rig(500, where)
				local res = interleave(r, {
					function()
						return r.build:place("shed", 0, 0, 0)
					end,
					function()
						-- runs while the place is parked inside its charge
						local uid = r.layout:pieces()[1].uid
						local refund, sellWhy = r.build:sell(uid)
						local moved, moveWhy = r.build:move(uid, 4, 4, 0)
						assert(refund == nil and sellWhy == "busy", `{where}: sell {tostring(sellWhy)}`)
						assert(moved == false and moveWhy == "busy", `{where}: move {tostring(moveWhy)}`)
						return refund, sellWhy
					end,
				}, { 1, 2 })
				assert(res[1][1] ~= nil, `{where}: the place still lands`)
				assert(r.wallet.coins == 380 and #r.layout:pieces() == 1, `{where}: coins {r.wallet.coins}`)
				-- control: once the charge has landed the piece can be sold
				assert(r.build:sell(res[1][1].uid) == 60)
			end
		end,
	},
	{
		name = "yield: an undo that reaches a piece waiting on its charge is refused as busy and kept",
		run = function()
			for _, where in wheres do
				local r = rig(500, where)
				local shed = placed(r, "shed", 0, 0)
				r.build:sell(shed.uid)
				local res = interleave(r, {
					function()
						return r.build:undo() -- the sell: the shed goes back, pending its charge
					end,
					function()
						return r.build:undo() -- the place: its piece is the pending shed
					end,
				}, { 1, 2 })
				assert(res[1][1] == "sell", `{where}: {tostring(res[1][2])}`)
				assert(res[2][1] == nil and res[2][2] == "busy", `{where}: {tostring(res[2][2])}`)
				assert(r.wallet.coins == 380 and #r.layout:pieces() == 1)
				assert(r.build:undo() == "place", `{where}: the place entry was kept`)
				assert(r.wallet.coins == 500 and #r.layout:pieces() == 0)
			end
		end,
	},
	{
		name = "commit runs before every wallet call, holding the layout as it will be",
		run = function()
			local r = rig(500, "after")
			local seen: { string } = {}
			local charge, credit = r.wallet.charge, r.wallet.credit
			r.wallet.charge = function(self, amount, reason)
				table.insert(seen, `charge {r.commits[#r.commits]}`)
				return charge(self, amount, reason)
			end
			r.wallet.credit = function(self, amount, reason)
				table.insert(seen, `credit {r.commits[#r.commits]}`)
				return credit(self, amount, reason)
			end
			local shed = placed(r, "shed", 0, 0) -- charged with 1 piece committed
			r.build:sell(shed.uid) -- credited with 0 committed
			r.build:undo() -- undo sell: charged with 1 committed
			r.build:undo() -- undo place: credited with 0 committed
			local want = { "charge 1", "credit 0", "charge 1", "credit 0" }
			assert(Deep.equal(seen, want), table.concat(seen, ", "))
			-- a refused charge commits the rollback as well
			r.wallet.coins = 0
			local piece, why = r.build:place("shed", 0, 0, 0)
			assert(piece == nil and why == "cant_afford")
			assert(r.commits[#r.commits] == 0 and r.commits[#r.commits - 1] == 1)
			-- control: a refusal before any change commits nothing
			local count = #r.commits
			r.build:place("unicorn", 0, 0, 0)
			r.build:sell(999)
			assert(#r.commits == count)
		end,
	},
	{
		name = "a charge that throws takes the unpaid piece off again and raises",
		run = function()
			local r = rig(500, "after")
			local real = r.wallet.charge
			r.wallet.charge = function()
				error("ledger offline")
			end
			local ok, err = pcall(function()
				r.build:place("shed", 0, 0, 0)
			end)
			assert(not ok and string.find(tostring(err), "ledger offline", 1, true), tostring(err))
			assert(#r.layout:pieces() == 0 and r.commits[#r.commits] == 0, "no unpaid piece is left")
			assert(r.wallet.coins == 500 and #r.build.history == 0)
			-- undo sell: the piece comes off again and the entry is kept for another try
			r.wallet.charge = real
			local shed = placed(r, "shed", 0, 0)
			r.build:sell(shed.uid)
			r.wallet.charge = function()
				error("ledger offline")
			end
			assert(not pcall(function()
				r.build:undo()
			end))
			assert(#r.layout:pieces() == 0 and r.wallet.coins == 440)
			assert(r.build.pending[shed.uid] == nil, "nothing is left pending")
			-- control: with the wallet back, the kept entry undoes the sale
			r.wallet.charge = real
			assert(r.build:undo() == "sell" and r.wallet.coins == 380 and #r.layout:pieces() == 1)
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
