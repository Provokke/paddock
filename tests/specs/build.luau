--!strict
local Config = require("../../src/shared/Config")
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local Layout = require("../../src/shared/Layout")
local Wallet = require("../../src/server/Wallet")
local Build = require("../../src/server/Build")

type Rig = {
	build: any,
	layout: any,
	wallet: any,
	clock: any,
	defs: any,
	data: { coins: number },
}

-- The shipped Config is frozen, so each rig gets a mutable deep copy of the defs.
local function rig(coins: number, sellRefund: number?, undoDepth: number?): Rig
	local defs = Deep.copy(Config.Placeables)
	local layout = Layout.new(10, 8, defs)
	local data = { coins = coins }
	local wallet = Wallet.new(data)
	local clock = FakeClock.new(1000)
	local build = Build.new({
		layout = layout,
		wallet = wallet,
		defs = defs,
		sellRefund = sellRefund or 0.5,
		undoDepth = undoDepth or 3,
		undoSeconds = 30,
		now = function()
			return clock:now()
		end,
	})
	return { build = build, layout = layout, wallet = wallet, clock = clock, defs = defs, data = data }
end

local function state(r: Rig): any
	return Deep.copy({ coins = r.wallet:balance(), pieces = r.layout:pieces() })
end

local function placed(r: Rig, id: string, x: number, z: number, rot: number): any
	local piece, why = r.build:place(id, x, z, rot)
	assert(piece ~= nil, `{id} at {x},{z} should place, got {tostring(why)}`)
	return piece
end

-- The undo must refuse with `why` and leave both the balance and the layout exactly as they were.
local function undoRefused(r: Rig, why: string)
	local before = state(r)
	local kind, got = r.build:undo()
	assert(kind == nil, `expected a refusal, undid {tostring(kind)}`)
	assert(got == why, `expected {why}, got {tostring(got)}`)
	assert(Deep.equal(before, state(r)), "an undo refusal changed the balance or the layout")
end

return {
	{
		name = "place charges exactly the cost",
		run = function()
			local r = rig(500)
			local piece = placed(r, "shed", 0, 0, 0)
			assert(piece.id == "shed")
			assert(r.wallet:balance() == 380)
			assert(#r.layout:pieces() == 1)
		end,
	},
	{
		name = "a failed place charges nothing",
		run = function()
			local r = rig(500)
			placed(r, "hay_bale", 5, 5, 0)
			placed(r, "shed", 0, 0, 0)
			placed(r, "shed", 4, 0, 0)
			local cases: { { id: string, x: number, z: number, why: string } } = {
				{ id = "fence", x = 9, z = 0, why = "out_of_bounds" },
				{ id = "hay_bale", x = 5, z = 5, why = "overlap" },
				{ id = "shed", x = 0, z = 4, why = "limit" },
				{ id = "unicorn", x = 0, z = 6, why = "unknown_item" },
			}
			for _, c in cases do
				local before = state(r)
				local piece, why = r.build:place(c.id, c.x, c.z, 0)
				assert(piece == nil, `{c.id} should not place`)
				assert(why == c.why, `{c.id}: expected {c.why}, got {tostring(why)}`)
				assert(Deep.equal(before, state(r)), `{c.id} changed the state on a failed place`)
			end
		end,
	},
	{
		name = "a bad rotation charges nothing",
		run = function()
			local r = rig(500)
			local before = state(r)
			local piece, why = r.build:place("shed", 0, 0, 5)
			assert(piece == nil and why == "bad_rotation")
			assert(Deep.equal(before, state(r)))
		end,
	},
	{
		name = "cant_afford leaves no piece and the balance alone",
		run = function()
			local r = rig(100)
			local piece, why = r.build:place("shed", 0, 0, 0)
			assert(piece == nil)
			assert(why == "cant_afford")
			assert(#r.layout:pieces() == 0)
			assert(r.wallet:balance() == 100)
		end,
	},
	{
		name = "double spend: 130 Coins buys one shed, not two",
		run = function()
			local r = rig(130)
			local first = r.build:place("shed", 0, 0, 0)
			local second, why = r.build:place("shed", 4, 0, 0)
			assert(first ~= nil)
			assert(second == nil)
			assert(why == "cant_afford")
			assert(#r.layout:pieces() == 1)
			assert(r.wallet:balance() == 10)
		end,
	},
	{
		name = "double spend negative control: 240 Coins buys both",
		run = function()
			local r = rig(240)
			local first = r.build:place("shed", 0, 0, 0)
			local second, why = r.build:place("shed", 4, 0, 0)
			assert(first ~= nil, "first place failed")
			assert(second ~= nil, `second place failed: {tostring(why)}`)
			assert(#r.layout:pieces() == 2)
			assert(r.wallet:balance() == 0)
		end,
	},
	{
		name = "sell refunds half the cost and removes the piece",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			assert(r.wallet:balance() == 380)
			local refund, why = r.build:sell(shed.uid)
			assert(refund == 60, tostring(why))
			assert(r.wallet:balance() == 440)
			assert(r.layout:get(shed.uid) == nil)
			local fence = placed(r, "fence", 0, 4, 0)
			assert(r.wallet:balance() == 430)
			assert(r.build:sell(fence.uid) == 5)
			assert(r.wallet:balance() == 435)
		end,
	},
	{
		name = "sell refund is floored",
		run = function()
			local r = rig(500, 0.3)
			local hay = placed(r, "hay_bale", 0, 0, 0)
			assert(r.build:sell(hay.uid) == 4)
			assert(r.wallet:balance() == 500 - 15 + 4)
		end,
	},
	{
		name = "selling the same uid twice credits once",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			assert(r.build:sell(shed.uid) == 60)
			local before = state(r)
			local refund, why = r.build:sell(shed.uid)
			assert(refund == nil)
			assert(why == "no_piece")
			assert(Deep.equal(before, state(r)))
			local refund2, why2 = r.build:sell(9999)
			assert(refund2 == nil and why2 == "no_piece")
			assert(Deep.equal(before, state(r)))
		end,
	},
	{
		name = "move is free",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			local ok, why = r.build:move(shed.uid, 5, 4, 1)
			assert(ok == true, tostring(why))
			assert(r.wallet:balance() == 380)
			local now = r.layout:get(shed.uid)
			assert(now.x == 5 and now.z == 4 and now.r == 1)
		end,
	},
	{
		name = "a refused move changes nothing and adds no history",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			local before = state(r)
			local ok, why = r.build:move(shed.uid, 9, 0, 0)
			assert(ok == false and why == "out_of_bounds")
			local ok2, why2 = r.build:move(777, 0, 0, 0)
			assert(ok2 == false and why2 == "no_piece")
			assert(Deep.equal(before, state(r)))
			assert(r.build:undo() == "place", "the refused moves must not have been pushed to history")
		end,
	},
	{
		name = "undo place removes the piece and refunds the charge",
		run = function()
			local r = rig(500)
			placed(r, "shed", 0, 0, 0)
			assert(r.build:undo() == "place")
			assert(r.wallet:balance() == 500)
			assert(#r.layout:pieces() == 0)
			local kind, why = r.build:undo()
			assert(kind == nil and why == "nothing")
		end,
	},
	{
		name = "undo place refunds the stored charge, not the current catalogue price",
		run = function()
			local r = rig(500)
			placed(r, "shed", 0, 0, 0)
			assert(r.wallet:balance() == 380)
			r.defs.shed.cost = 200 -- a config change between place and undo
			assert(r.build:undo() == "place")
			assert(r.wallet:balance() == 500, "the refund must equal the 120 actually charged")
		end,
	},
	{
		name = "undo place refunds the stored charge when the price drops",
		run = function()
			local r = rig(500)
			placed(r, "shed", 0, 0, 0)
			r.defs.shed.cost = 10
			assert(r.build:undo() == "place")
			assert(r.wallet:balance() == 500, "a cheaper catalogue must not burn coins")
		end,
	},
	{
		name = "undo sell charges back the stored refund, not a fresh one",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			assert(r.build:sell(shed.uid) == 60)
			assert(r.wallet:balance() == 440)
			r.defs.shed.cost = 400
			assert(r.build:undo() == "sell")
			assert(r.wallet:balance() == 380, "the charge back must equal the 60 actually paid")
		end,
	},
	{
		name = "undo move returns the piece to its old cell and rotation",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			assert(r.build:move(shed.uid, 5, 4, 1))
			assert(r.build:undo() == "move")
			local back = r.layout:get(shed.uid)
			assert(back.x == 0 and back.z == 0 and back.r == 0)
			assert(r.wallet:balance() == 380)
		end,
	},
	{
		name = "undo sell puts the piece back under its uid and charges the refund",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 2, 1, 1)
			assert(r.build:sell(shed.uid) == 60)
			assert(r.build:undo() == "sell")
			local back = r.layout:get(shed.uid)
			assert(back ~= nil, "the piece should be back under its old uid")
			assert(back.id == "shed" and back.x == 2 and back.z == 1 and back.r == 1)
			assert(r.wallet:balance() == 500 - 120)
			assert(r.build:undo() == "place")
			assert(r.wallet:balance() == 500)
			assert(#r.layout:pieces() == 0)
		end,
	},
	{
		name = "undo is LIFO across kinds",
		run = function()
			local r = rig(120)
			local shed = placed(r, "shed", 0, 0, 0)
			assert(r.wallet:balance() == 0)
			assert(r.build:sell(shed.uid) == 60)
			placed(r, "trough", 0, 4, 0)
			assert(r.wallet:balance() == 20)
			assert(r.build:undo() == "place")
			assert(r.wallet:balance() == 60)
			assert(#r.layout:pieces() == 0)
			assert(r.build:undo() == "sell")
			assert(r.wallet:balance() == 0)
			assert(r.layout:get(shed.uid) ~= nil)
			assert(r.build:undo() == "place")
			assert(r.wallet:balance() == 120)
			assert(#r.layout:pieces() == 0)
		end,
	},
	{
		name = "undo sell refused when the cells were taken outside Build",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			assert(r.build:sell(shed.uid) == 60)
			assert(r.wallet:balance() == 440)
			local direct = r.layout:place("shed", 0, 0, 0)
			assert(direct ~= nil)
			undoRefused(r, "overlap")
			assert(r.wallet:balance() == 440, "the charge must have been credited back")
			assert(r.layout:get(direct.uid) ~= nil, "the direct piece must be untouched")
			r.layout:remove(direct.uid)
			assert(r.build:undo() == "sell", "the entry must stay undoable")
			local back = r.layout:get(shed.uid)
			assert(back ~= nil and back.x == 0 and back.z == 0)
		end,
	},
	{
		name = "undo sell refused when the shed limit was reached outside Build",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			assert(r.build:sell(shed.uid) == 60)
			assert(r.layout:place("shed", 4, 0, 0))
			assert(r.layout:place("shed", 4, 4, 0))
			undoRefused(r, "limit")
			assert(r.wallet:balance() == 440)
		end,
	},
	{
		name = "undo sell refused when the coins were spent outside Build",
		run = function()
			local r = rig(120)
			local shed = placed(r, "shed", 0, 0, 0)
			assert(r.build:sell(shed.uid) == 60)
			assert(r.wallet:charge(60, "test"))
			assert(r.wallet:balance() == 0)
			undoRefused(r, "cant_afford")
			assert(r.layout:get(shed.uid) == nil, "the shed must not be back")
			assert(r.wallet:credit(60, "test"))
			assert(r.build:undo() == "sell")
			assert(r.layout:get(shed.uid) ~= nil)
			assert(r.wallet:balance() == 0)
		end,
	},
	{
		name = "undo place refused when the piece is already gone",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			r.layout:remove(shed.uid)
			undoRefused(r, "no_piece")
			assert(r.wallet:balance() == 380, "no refund for a piece that is not there")
		end,
	},
	{
		name = "undo move refused when the old cell is taken, and when the piece is gone",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			assert(r.build:move(shed.uid, 5, 4, 0))
			local direct = r.layout:place("hay_bale", 0, 0, 0)
			assert(direct ~= nil)
			undoRefused(r, "overlap")
			assert(r.layout:get(shed.uid).x == 5)
			r.layout:remove(direct.uid)
			r.layout:remove(shed.uid)
			undoRefused(r, "no_piece")
		end,
	},
	{
		name = "undo move refused when the old cell is now out of bounds",
		run = function()
			-- The layout is shrunk to stand in for an outside change to the plot.
			local r = rig(500)
			local shed = placed(r, "shed", 7, 0, 0)
			assert(r.build:move(shed.uid, 0, 0, 0))
			r.layout.width = 5
			undoRefused(r, "out_of_bounds")
		end,
	},
	{
		name = "expiry: an entry older than 30 seconds cannot be undone",
		run = function()
			local r = rig(500)
			placed(r, "shed", 0, 0, 0)
			r.clock:advance(31)
			undoRefused(r, "expired")
			assert(r.wallet:balance() == 380)
			assert(#r.layout:pieces() == 1)
		end,
	},
	{
		name = "expiry: exactly 30 seconds is still undoable, and expiry clears older entries too",
		run = function()
			local r = rig(500)
			placed(r, "fence", 0, 0, 0)
			r.clock:advance(30)
			assert(r.build:undo() == "place", "30 s exactly is not older than 30 s")
			placed(r, "fence", 0, 0, 0)
			placed(r, "fence", 0, 2, 0)
			r.clock:advance(31)
			undoRefused(r, "expired")
			local kind, why = r.build:undo()
			assert(kind == nil and why == "nothing", "everything older than an expired entry goes with it")
		end,
	},
	{
		name = "depth: only 3 undos after 4 places",
		run = function()
			local r = rig(500)
			for i = 0, 3 do
				placed(r, "fence", 0, i * 2, 0)
			end
			assert(r.build:undo() == "place")
			assert(r.build:undo() == "place")
			assert(r.build:undo() == "place")
			local kind, why = r.build:undo()
			assert(kind == nil and why == "nothing")
			assert(#r.layout:pieces() == 1, "the oldest placement is not undoable")
		end,
	},
	{
		name = "undo is never pushed to history",
		run = function()
			local r = rig(500)
			placed(r, "fence", 0, 0, 0)
			assert(r.build:undo() == "place")
			local kind, why = r.build:undo()
			assert(kind == nil and why == "nothing")
			assert(r.wallet:balance() == 500)
		end,
	},
	{
		name = "snapshot reports coins and pieces as a copy",
		run = function()
			local r = rig(500)
			local shed = placed(r, "shed", 0, 0, 0)
			local snap = r.build:snapshot()
			assert(snap.coins == 380)
			assert(#snap.pieces == 1 and snap.pieces[1].uid == shed.uid)
			snap.pieces[1].x = 9
			assert(r.layout:get(shed.uid).x == 0, "the snapshot must be a copy")
		end,
	},
}
