--!strict
-- The server entry script itself, run under Lune over FakeGame: joining, plots, placing, what a
-- rejoin restores, and a saved layout that no longer fits.
local FakeGame = require("../fakes/FakeGame")

local PLOT_SIZE = { 40, 1, 40 } -- 10 by 10 cells at 4 studs a cell

local function started(options: any?): any
	local world = FakeGame.new(options)
	for index = 1, 4 do
		world:addPlot(index, PLOT_SIZE, FakeGame.cframe(index * 100, 0, 50))
	end
	world:start()
	assert(world.started == true, world.startError)
	return world
end

local function stored(world: any, userId: number): any
	local record = world.records["Player_" .. userId]
	return if record ~= nil then record.data else nil
end

local function count(t: any): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

return {
	{
		name = "a config that fails its checks refuses to start, with a warning",
		run = function()
			local bad = table.clone(require("../../src/shared/Config"))
			bad.CellSize = 0
			local world = FakeGame.new({ config = bad })
			world:addPlot(1, PLOT_SIZE)
			world:start()
			assert(world.started == true, world.startError)
			assert(world:remote("Request") == nil, "nothing else started")
			local found = false
			for _, line in world.warnings do
				if string.find(line, "CellSize", 1, true) then
					found = true
				end
			end
			assert(found, "the problem is warned about")
		end,
	},
	{
		name = "a joining player gets plot 1 and 500 coins",
		run = function()
			local world = started()
			world:join(1)
			local sync = world:lastSync(1)
			assert(sync ~= nil, "synced")
			assert(sync.plot == 1, tostring(sync.plot))
			assert(sync.coins == 500, tostring(sync.coins))
			assert(#sync.pieces == 0 and sync.cellSize == 4)
			assert(sync.plotSize[1] == 10 and sync.plotSize[2] == 10)
			world:join(2)
			assert(world:lastSync(2).plot == 2, "the next player gets the next plot")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a place request charges, is written into the session data and appears as a model",
		run = function()
			local world = started()
			world:join(1)
			world:request(1, "place", "fence", 0, 0, 0)
			local sync = world:lastSync(1)
			assert(sync.coins == 490, tostring(sync.coins))
			assert(#sync.pieces == 1 and sync.pieces[1].id == "fence")
			local models = world:models(1)
			assert(count(models) == 1 and models[sync.pieces[1].uid] ~= nil, "one model, tagged with its uid")
			-- plot 1 is at (100, 0, 50), 40 by 1 by 40. Fence cell (0,0) is 2 by 1 cells, centred at
			-- (4, 2) from the min corner, on the top face (0.5) with the box's half height (1) added.
			local at = models[sync.pieces[1].uid].pivot.Position
			assert(at.X == 100 - 20 + 4 and at.Z == 50 - 20 + 2, `{at.X}, {at.Z}`)
			assert(at.Y == 0.5 + 1, tostring(at.Y))
			world:leave(1)
			local data = stored(world, 1)
			assert(data.coins == 490, tostring(data.coins))
			assert(#data.layout == 1, `{#data.layout} saved pieces`)
			local saved = data.layout[1]
			assert(saved.id == "fence" and saved.x == 0 and saved.z == 0 and saved.r == 0)
			assert(saved.uid == nil, "the save holds { id, x, z, r } only")
			assert(count(world:models(1)) == 0, "the plot's models are gone when they leave")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "sell and move change the models, and only the changed piece is rebuilt",
		run = function()
			local world = started()
			world:join(1)
			world:request(1, "place", "fence", 0, 0, 0)
			world:request(1, "place", "tree", 5, 5, 0)
			local first = world:lastSync(1).pieces
			assert(#first == 2)
			local before = world:models(1)
			world:request(1, "move", first[2].uid, 6, 6, 0)
			local after = world:models(1)
			assert(after[first[1].uid] == before[first[1].uid], "the other piece was left alone")
			assert(after[first[2].uid] ~= before[first[2].uid], "the moved piece was rebuilt")
			world:request(1, "sell", first[1].uid)
			assert(count(world:models(1)) == 1)
			assert(world:lastSync(1).coins == 500 - 10 - 25 + 5, tostring(world:lastSync(1).coins))
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a rejoin with the saved data restores the piece, on a restarted server",
		run = function()
			local world = started()
			world:join(1)
			world:request(1, "place", "shed", 2, 2, 1)
			world:leave(1)
			world.sched:advance(1)
			-- A new server script over the same store.
			local again = started({ records = world.records })
			again:join(1)
			local sync = again:lastSync(1)
			assert(sync ~= nil and sync.plot == 1)
			assert(sync.coins == 380, tostring(sync.coins))
			assert(#sync.pieces == 1, `{#sync.pieces} pieces`)
			local piece = sync.pieces[1]
			assert(piece.id == "shed" and piece.x == 2 and piece.z == 2 and piece.r == 1)
			assert(count(again:models(1)) == 1, "its model is back")
			-- control: nothing was refunded for a piece that still fits
			again:leave(1)
			assert(stored(again, 1).coins == 380 and #stored(again, 1).layout == 1)
			assert(#again.errors == 0, again.errors[1])
		end,
	},
	{
		name = "a saved shed that no longer fits is refunded 60 on join and leaves the save",
		run = function()
			local world = started()
			world.records.Player_1 = {
				schema = 1,
				savedAt = 0,
				data = {
					coins = 100,
					layout = {
						{ id = "fence", x = 0, z = 0, r = 0 },
						{ id = "shed", x = 9, z = 9, r = 0 }, -- hangs off the 10 by 10 plot
					},
				},
			}
			world:join(1)
			local sync = world:lastSync(1)
			assert(sync.coins == 160, `{sync.coins} coins`)
			assert(#sync.pieces == 1 and sync.pieces[1].id == "fence")
			world:leave(1)
			local data = stored(world, 1)
			assert(data.coins == 160, tostring(data.coins))
			assert(#data.layout == 1 and data.layout[1].id == "fence", "the dropped shed left the save")
			-- control: coming back again refunds nothing more
			world.sched:advance(1)
			world:join(1)
			assert(world:lastSync(1).coins == 160)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a fifth player gets no plot, and their place request is dropped",
		run = function()
			local world = started()
			for id = 1, 4 do
				world:join(id)
			end
			world:join(5)
			local sync = world:lastSync(5)
			assert(sync ~= nil, "they are still synced")
			assert(sync.plot == nil and sync.plotSize == nil, "no plot")
			assert(sync.coins == 500)
			assert(#sync.pieces == 0)
			local sent = #world.synced
			world:request(5, "place", "fence", 0, 0, 0)
			assert(#world.synced == sent, "dropped: no build, so no sync")
			assert(stored(world, 5) == nil or #stored(world, 5).layout == 0)
			-- control: when a plot frees up, the next player to join gets it
			world:leave(2)
			world:join(6)
			assert(world:lastSync(6).plot == 2)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a player with no plot keeps a saved layout instead of losing it",
		run = function()
			local world = started()
			world.records.Player_5 = {
				schema = 1,
				savedAt = 0,
				data = { coins = 50, layout = { { id = "fence", x = 0, z = 0, r = 0 } } },
			}
			for id = 1, 4 do
				world:join(id)
			end
			world:join(5)
			assert(world:lastSync(5).plot == nil)
			world:leave(5)
			assert(#stored(world, 5).layout == 1 and stored(world, 5).coins == 50)
		end,
	},
	{
		name = "bad requests are dropped and cost nothing",
		run = function()
			local world = started()
			world:join(1)
			local sent = #world.synced
			world:request(1, "place", "fence", 1.5, 0, 0)
			world:request(1, "place", "fence", 0, 0, 4)
			world:request(1, "place", string.rep("x", 40), 0, 0, 0)
			world:request(1, "launch", 1)
			world:request(1, "sell", 0)
			assert(#world.synced == sent)
			assert(world:lastSync(1).coins == 500)
			-- control: a good one still works afterwards
			world:request(1, "place", "fence", 0, 0, 0)
			assert(world:lastSync(1).coins == 490)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a plot too small for a cell is not used",
		run = function()
			local world = FakeGame.new()
			world:addPlot(1, { 3, 1, 40 })
			world:addPlot(2, PLOT_SIZE)
			world:start()
			world:join(1)
			assert(world:lastSync(1).plot == 2)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
}
