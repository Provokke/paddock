--!strict
local Config = require("../../src/shared/Config")
local Layout = require("../../src/shared/Layout")
local Restore = require("../../src/server/Restore")

local function fresh(): any
	return Layout.new(10, 8, Config.Placeables)
end

local function run(entries: any, layout: any): any
	return Restore.run(entries, layout, Config.Placeables, Config.SellRefund)
end

return {
	{
		name = "a good layout is kept whole with no refund",
		run = function()
			local layout = fresh()
			local out = run({
				{ id = "fence", x = 0, z = 0, r = 0 },
				{ id = "hay_bale", x = 4, z = 0, r = 0 },
				{ id = "tree", x = 6, z = 3, r = 0 },
			}, layout)
			assert(out.kept == 3 and out.refund == 0 and #out.dropped == 0, `{out.kept} {out.refund}`)
			assert(#layout:pieces() == 3)
		end,
	},
	{
		name = "bad entries are dropped with their reasons and refunded only when they were real pieces",
		run = function()
			local layout = fresh()
			local out = run({
				{ id = "shed", x = 9, z = 0, r = 0 },
				{ id = "ghost", x = 0, z = 0, r = 0 },
				{ id = "tree", x = "a", z = 0, r = 0 },
				{ id = "hay_bale", x = 0, z = 5, r = 0 },
				{ id = "hay_bale", x = 0, z = 5, r = 0 },
				{ id = "fence", x = 4, z = 5, r = 0 },
			}, layout)
			assert(out.kept == 2, `kept {out.kept}`)
			assert(out.refund == 67, `refund {out.refund}`)
			assert(#out.dropped == 4)
			assert(out.dropped[1].reason == "out_of_bounds" and out.dropped[1].entry.id == "shed")
			assert(out.dropped[2].reason == "unknown_item")
			assert(out.dropped[3].reason == "malformed")
			assert(out.dropped[4].reason == "overlap")
		end,
	},
	{
		name = "malformed entries are never refunded and never reach the layout",
		run = function()
			local layout = fresh()
			local out = run({
				"junk",
				{ id = 5, x = 0, z = 0, r = 0 },
				{ id = "fence", x = 0.5, z = 0, r = 0 },
				{ id = "fence", x = 0, z = 0 / 0, r = 0 },
				{ id = "fence", x = 0, z = 0, r = math.huge },
				{ id = "fence", x = 0, z = 0 },
			}, layout)
			assert(out.kept == 0 and out.refund == 0 and #out.dropped == 6)
			for _, d in out.dropped do
				assert(d.reason == "malformed")
			end
			assert(#layout:pieces() == 0)
		end,
	},
	{
		name = "three saved sheds keep two and drop the third by the limit",
		run = function()
			local out = run({
				{ id = "shed", x = 0, z = 0, r = 0 },
				{ id = "shed", x = 3, z = 0, r = 0 },
				{ id = "shed", x = 6, z = 0, r = 0 },
			}, fresh())
			assert(out.kept == 2 and #out.dropped == 1 and out.dropped[1].reason == "limit")
			assert(out.refund == 60, `refund {out.refund}`)
		end,
	},
	{
		name = "nil or a non-table list restores nothing and does not throw",
		run = function()
			for _, bad in { false, 7, "x" } do
				local out = run(bad, fresh())
				assert(out.kept == 0 and out.refund == 0 and #out.dropped == 0)
			end
			local out = run(nil, fresh())
			assert(out.kept == 0 and out.refund == 0 and #out.dropped == 0)
		end,
	},
}
