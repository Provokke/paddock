--!strict
-- What a new profile holds and how it is stored.
local Config = require("../../src/shared/Config")
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local Profile = require("../../src/server/Data/Profile")
local StoreServer = require("../fakes/StoreServer")

local function profile(): any
	return Profile.new({ startingCoins = Config.StartingCoins })
end

return {
	{
		name = "a new profile already holds the starting coins and an empty layout",
		run = function()
			local data = profile().defaultData()
			assert(data.coins == 500, "starting coins")
			assert(type(data.layout) == "table" and next(data.layout) == nil, "empty layout")
			-- control: two new profiles never share a table
			local other = profile().defaultData()
			table.insert(other.layout, { id = "fence", x = 0, z = 0, r = 0 })
			assert(next(data.layout) == nil)
		end,
	},
	{
		name = "starting coins are written by the first claim, once, even if the player leaves at once",
		run = function()
			local p = profile()
			local records: any = {}
			local store = StoreServer.new(records, FakeClock.new(0), "JOB", {
				defaultData = p.defaultData,
				encode = p.encode,
				decode = p.decode,
			})
			local first, outcome = store:load("p1")
			assert(first ~= nil and outcome == "new", outcome)
			assert(records.p1.data.coins == 500, "the claim itself wrote the coins")
			assert(first:release() == true) -- they left before any save
			local again, outcome2 = store:load("p1")
			assert(again ~= nil and outcome2 == "taken", outcome2)
			assert(again.data.coins == 500, "granted once, not again")
		end,
	},
	{
		name = "encode and decode keep every field, and the stored form shares nothing with the session",
		run = function()
			local p = profile()
			local data = p.defaultData()
			data.coins = 7
			table.insert(data.layout, { id = "fence", x = 1, z = 2, r = 90 })
			data.settings = { music = false }
			local stored = p.encode(data)
			assert(Deep.equal(stored, data), "every field is stored, including ones the module doesn't know")
			stored.layout[1].x = 9
			assert(data.layout[1].x == 1, "encode copies")
			assert(Deep.equal(p.decode(p.encode(data)), data), "and the round trip is whole")
		end,
	},
	{
		name = "data that isn't a table, or has no coins, is refused instead of opened as a fresh profile",
		run = function()
			local p = profile()
			assert(pcall(p.decode, "oops") == false)
			assert(pcall(p.decode, { layout = {} }) == false, "no coins")
			-- control: a whole record decodes
			assert(pcall(p.decode, p.defaultData()) == true)
			-- a record without a layout gets an empty one
			local out = p.decode({ coins = 3 })
			assert(out.coins == 3 and type(out.layout) == "table" and next(out.layout) == nil)
			-- and a saved layout is kept
			local kept = p.decode({ coins = 0, layout = { { id = "tree", x = 0, z = 0, r = 0 } } })
			assert(kept.layout[1].id == "tree")
		end,
	},
}
