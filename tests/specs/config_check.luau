--!strict
local Config = require("../../src/shared/Config")
local ConfigCheck = require("../../src/shared/ConfigCheck")
local Deep = require("../fakes/Deep")

-- Breaks a deep copy of the shipped config with `change`, and checks the check fails with a
-- reason that names `needle`. The unbroken copy must pass first, so a failure is the change's.
local function flagged(change: (config: any) -> (), needle: string)
	local config = Deep.copy(Config)
	assert(ConfigCheck.check(config), "control: the shipped config is clean")
	change(config)
	local ok, reason = ConfigCheck.check(config)
	assert(ok == false, `expected a failure naming "{needle}"`)
	assert(
		reason ~= nil and string.find(reason, needle, 1, true),
		`expected "{needle}", got: {tostring(reason)}`
	)
end

return {
	{
		name = "the shipped config passes",
		run = function()
			local ok, reason = ConfigCheck.check(Config)
			assert(ok, tostring(reason))
			assert(reason == nil, "no reason on success")
		end,
	},
	{
		name = "a missing or non-number field is flagged",
		run = function()
			flagged(function(c)
				c.CellSize = nil
			end, "CellSize")
			flagged(function(c)
				c.StartingCoins = "500"
			end, "StartingCoins")
			flagged(function(c)
				c.UndoSeconds = nil
			end, "UndoSeconds")
			flagged(function(c)
				c.SchemaVersion = {}
			end, "SchemaVersion")
		end,
	},
	{
		name = "a cell size of zero or less is flagged",
		run = function()
			flagged(function(c)
				c.CellSize = 0
			end, "CellSize")
			flagged(function(c)
				c.CellSize = -4
			end, "CellSize")
		end,
	},
	{
		name = "starting Coins must be a whole number of 0 or more",
		run = function()
			flagged(function(c)
				c.StartingCoins = -1
			end, "StartingCoins")
			flagged(function(c)
				c.StartingCoins = 10.5
			end, "StartingCoins")
			local config = Deep.copy(Config)
			config.StartingCoins = 0
			assert(ConfigCheck.check(config), "0 is allowed")
		end,
	},
	{
		name = "a sell refund outside 0 to 1 is flagged",
		run = function()
			flagged(function(c)
				c.SellRefund = -0.1
			end, "SellRefund")
			flagged(function(c)
				c.SellRefund = 1.5
			end, "SellRefund")
			for _, edge in { 0, 1 } do
				local config = Deep.copy(Config)
				config.SellRefund = edge
				assert(ConfigCheck.check(config), `{edge} is allowed`)
			end
		end,
	},
	{
		name = "undo depth must be whole and 0 or more, undo seconds 0 or more",
		run = function()
			flagged(function(c)
				c.UndoDepth = -1
			end, "UndoDepth")
			flagged(function(c)
				c.UndoDepth = 2.5
			end, "UndoDepth")
			flagged(function(c)
				c.UndoSeconds = -1
			end, "UndoSeconds")
		end,
	},
	{
		name = "a lease no longer than the autosave is flagged",
		run = function()
			flagged(function(c)
				c.LeaseSeconds = 60
			end, "LeaseSeconds")
			flagged(function(c)
				c.LeaseSeconds = 30
			end, "LeaseSeconds")
		end,
	},
	{
		name = "a placeable with a bad footprint, cost, count or name is flagged",
		run = function()
			flagged(function(c)
				c.Placeables.fence.w = 0
			end, "Placeables.fence.w")
			flagged(function(c)
				c.Placeables.fence.d = 1.5
			end, "Placeables.fence.d")
			flagged(function(c)
				c.Placeables.fence.cost = -1
			end, "Placeables.fence.cost")
			flagged(function(c)
				c.Placeables.fence.cost = 2.5
			end, "Placeables.fence.cost")
			flagged(function(c)
				c.Placeables.fence.maxCount = 0
			end, "Placeables.fence.maxCount")
			flagged(function(c)
				c.Placeables.fence.name = nil
			end, "Placeables.fence.name")
			local config = Deep.copy(Config)
			config.Placeables.fence.cost = 0
			assert(ConfigCheck.check(config), "a free piece is allowed")
		end,
	},
	{
		name = "limits of 0 or less are flagged",
		run = function()
			flagged(function(c)
				c.Limits.BurstPerPlayer = 0
			end, "Limits.BurstPerPlayer")
			flagged(function(c)
				c.Limits.RefillPerSecond = -1
			end, "Limits.RefillPerSecond")
		end,
	},
	{
		name = "a missing limit returns false rather than throwing",
		run = function()
			local config = Deep.copy(Config)
			config.Limits.BurstPerPlayer = nil
			local ok, reason = ConfigCheck.check(config)
			assert(ok == false, "should fail")
			assert(reason ~= nil and string.find(reason, "Limits.BurstPerPlayer", 1, true), tostring(reason))
			config.Limits = nil
			local ok2 = ConfigCheck.check(config)
			assert(ok2 == false, "a missing Limits table fails too")
		end,
	},
}
