--!strict
local Config = require("../../src/shared/Config")
local Deep = require("../fakes/Deep")
local Layout = require("../../src/shared/Layout")

local function fresh(): any
	return Layout.new(10, 8, Config.Placeables)
end

-- Runs `attempt`, expects it to fail with `why`, and checks the layout did not change.
local function refused(layout: any, why: string, attempt: () -> (any, string?))
	local before = Deep.copy(layout:pieces())
	local result, got = attempt()
	assert(not result, "expected a refusal")
	assert(got == why, `expected {why}, got {tostring(got)}`)
	assert(Deep.equal(before, layout:pieces()), "the layout changed on a failed call")
end

local function fits(layout: any, id: string, x: number, z: number, r: number)
	local ok, why = layout:canPlace(id, x, z, r)
	assert(ok, `{id} at {x},{z} r{r} should fit, got {tostring(why)}`)
end

local function reasonFor(layout: any, id: string, x: number, z: number, r: number): string?
	local ok, why = layout:canPlace(id, x, z, r)
	assert(not ok, `{id} at {x},{z} r{r} should not fit`)
	return why
end

return {
	{
		name = "bounds for a shed at rotation 0",
		run = function()
			local l = fresh()
			fits(l, "shed", 7, 6, 0)
			assert(reasonFor(l, "shed", 8, 6, 0) == "out_of_bounds")
			assert(reasonFor(l, "shed", 7, 7, 0) == "out_of_bounds")
			assert(reasonFor(l, "shed", -1, 0, 0) == "out_of_bounds")
		end,
	},
	{
		name = "bounds for a shed at rotation 1",
		run = function()
			local l = fresh()
			fits(l, "shed", 8, 5, 1)
			assert(reasonFor(l, "shed", 8, 6, 1) == "out_of_bounds")
		end,
	},
	{
		name = "overlap is refused, touching is not",
		run = function()
			local l = fresh()
			assert(l:place("shed", 0, 0, 0))
			assert(reasonFor(l, "hay_bale", 2, 1, 0) == "overlap")
			fits(l, "hay_bale", 3, 0, 0)
			local l2 = fresh()
			assert(l2:place("fence", 5, 5, 1))
			assert(reasonFor(l2, "hay_bale", 5, 6, 0) == "overlap")
		end,
	},
	{
		name = "the per-item limit holds, and removing a piece frees a slot",
		run = function()
			local l = fresh()
			local a = assert(l:place("shed", 0, 0, 0))
			assert(l:place("shed", 4, 0, 0))
			refused(l, "limit", function()
				return l:place("shed", 0, 4, 0)
			end)
			assert(l:remove(a.uid))
			assert(l:place("shed", 0, 4, 0))
		end,
	},
	{
		name = "move may overlap its own old cells",
		run = function()
			local l = fresh()
			local s = assert(l:place("shed", 0, 0, 0))
			local ok, why = l:move(s.uid, 1, 0, 0)
			assert(ok, tostring(why))
			local p = assert(l:get(s.uid))
			assert(p.x == 1 and p.z == 0)
		end,
	},
	{
		name = "a move that cannot happen leaves the piece where it was",
		run = function()
			local l = fresh()
			local s = assert(l:place("shed", 0, 0, 0))
			assert(l:place("hay_bale", 4, 0, 0))
			refused(l, "overlap", function()
				return l:move(s.uid, 2, 0, 0)
			end)
			local p = assert(l:get(s.uid))
			assert(p.x == 0 and p.z == 0)
			refused(l, "bad_rotation", function()
				return l:move(s.uid, 0, 0, 4)
			end)
			refused(l, "no_piece", function()
				return l:move(999, 0, 0, 0)
			end)
			refused(l, "out_of_bounds", function()
				return l:move(s.uid, 9, 0, 0)
			end)
		end,
	},
	{
		name = "unknown ids and bad rotations are refused",
		run = function()
			local l = fresh()
			refused(l, "unknown_item", function()
				return l:place("nope", 0, 0, 0)
			end)
			refused(l, "bad_rotation", function()
				return l:place("shed", 0, 0, 4)
			end)
			refused(l, "bad_rotation", function()
				return l:place("shed", 0, 0, 1.5)
			end)
			refused(l, "bad_rotation", function()
				return l:place("shed", 0, 0, -1)
			end)
		end,
	},
	{
		name = "uids count up and are never reused",
		run = function()
			local l = fresh()
			local a = assert(l:place("hay_bale", 0, 0, 0))
			local b = assert(l:place("hay_bale", 1, 0, 0))
			local c = assert(l:place("hay_bale", 2, 0, 0))
			assert(a.uid == 1 and b.uid == 2 and c.uid == 3)
			assert(l:remove(2))
			local d = assert(l:place("hay_bale", 1, 0, 0))
			assert(d.uid == 4, `got {d.uid}`)
		end,
	},
	{
		name = "placeWithUid restores a sold piece and refuses a live uid",
		run = function()
			local l = fresh()
			assert(l:place("hay_bale", 0, 0, 0))
			assert(l:place("hay_bale", 1, 0, 0))
			assert(l:remove(2))
			local back = assert(l:placeWithUid(2, "hay_bale", 1, 0, 0))
			assert(back.uid == 2)
			refused(l, "uid_taken", function()
				return l:placeWithUid(2, "hay_bale", 5, 5, 0)
			end)
			-- a restored uid must not collide with the next fresh one
			local nxt = assert(l:place("hay_bale", 6, 0, 0))
			assert(nxt.uid == 3, `got {nxt.uid}`)
		end,
	},
	{
		name = "placeWithUid applies the same rules as place",
		run = function()
			local l = fresh()
			assert(l:place("shed", 0, 0, 0))
			refused(l, "overlap", function()
				return l:placeWithUid(7, "hay_bale", 1, 1, 0)
			end)
			refused(l, "unknown_item", function()
				return l:placeWithUid(7, "nope", 6, 6, 0)
			end)
		end,
	},
	{
		name = "count, get and remove",
		run = function()
			local l = fresh()
			assert(l:count("shed") == 0)
			local s = assert(l:place("shed", 0, 0, 0))
			assert(l:count("shed") == 1)
			assert(l:get(99) == nil)
			local gone = assert(l:remove(s.uid))
			assert(gone.id == "shed")
			assert(l:remove(s.uid) == nil)
			assert(l:count("shed") == 0)
			assert(#l:pieces() == 0)
		end,
	},
	{
		name = "pieces are sorted by uid and are copies",
		run = function()
			local l = fresh()
			assert(l:place("hay_bale", 0, 0, 0))
			assert(l:place("hay_bale", 1, 0, 0))
			assert(l:placeWithUid(9, "hay_bale", 2, 0, 0))
			assert(l:placeWithUid(5, "hay_bale", 3, 0, 0))
			local list = l:pieces()
			local uids = {}
			for _, p in list do
				table.insert(uids, p.uid)
			end
			assert(table.concat(uids, ",") == "1,2,5,9", table.concat(uids, ","))
			list[1].x = 7
			list[1].id = "tree"
			local p = assert(l:get(1))
			assert(p.x == 0 and p.id == "hay_bale", "a copy changed the layout")
			p.x = 8
			assert(assert(l:get(1)).x == 0, "get returned the live piece")
		end,
	},
	{
		name = "a moved piece frees its old cells",
		run = function()
			local l = fresh()
			local s = assert(l:place("shed", 0, 0, 0))
			assert(l:move(s.uid, 5, 5, 0))
			fits(l, "hay_bale", 0, 0, 0)
			assert(reasonFor(l, "hay_bale", 5, 5, 0) == "overlap")
		end,
	},
}
