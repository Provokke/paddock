--!strict
-- The server entry script itself, run under Lune over FakeGame: joining, plots, placing, what a
-- rejoin restores, a saved layout that no longer fits, and wallets that yield or keep their Coins
-- somewhere else.
local FakeGame = require("../fakes/FakeGame")
local Wallet = require("../../src/server/Wallet")

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

-- The shipped Wallet with an onChange that waits `seconds`, as a wallet over a DataStore might.
-- `seen` records the session data at each wait: what a save made during the wait would hold.
local function yielding(seconds: number): any
	local probe: any = { seen = {} }
	function probe.wallet(world: any, data: any): any
		return Wallet.new(data, function()
			table.insert(probe.seen, { coins = data.coins, pieces = #data.layout })
			world.sched:wait(seconds)
		end)
	end
	return probe
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
	{
		name = "a sell, then a leave while the wallet yields, saves 440 Coins and no piece",
		run = function()
			-- The shipped Wallet with an onChange that yields, as a wallet over a DataStore might.
			local probe = yielding(1)
			local world = started({ wallet = probe.wallet })
			world:join(1)
			world:request(1, "place", "shed", 2, 2, 0)
			world.sched:advance(1)
			local sync = world:lastSync(1)
			assert(sync.coins == 380 and #sync.pieces == 1)
			world:request(1, "sell", sync.pieces[1].uid)
			local seen = probe.seen[#probe.seen]
			assert(seen.coins == 440 and seen.pieces == 0, `mid-yield {seen.coins} and {seen.pieces}`)
			world:leave(1)
			assert(world.records.Player_1.lease ~= nil, "the release waits for the sell to finish")
			world.sched:advance(3)
			local data = stored(world, 1)
			assert(world.records.Player_1.lease == nil, "and then lands")
			assert(data.coins == 440 and #data.layout == 0, `saved {data.coins} and {#data.layout} pieces`)
			-- the rejoin on a restarted server agrees
			local again = started({ records = world.records })
			again:join(1)
			local back = again:lastSync(1)
			assert(back.coins == 440 and #back.pieces == 0, `rejoined with {back.coins} and {#back.pieces}`)
			assert(#world.errors == 0, world.errors[1])
			-- control: the same sell with the leave after the wallet call saves the same
			local calm = started({ wallet = yielding(1).wallet })
			calm:join(1)
			calm:request(1, "place", "shed", 2, 2, 0)
			calm.sched:advance(1)
			calm:request(1, "sell", calm:lastSync(1).pieces[1].uid)
			calm.sched:advance(1)
			calm:leave(1)
			calm.sched:advance(2)
			assert(stored(calm, 1).coins == 440 and #stored(calm, 1).layout == 0)
		end,
	},
	{
		name = "a place, then a leave while the wallet yields, saves the charge with the piece",
		run = function()
			local probe = yielding(1)
			local world = started({ wallet = probe.wallet })
			world:join(1)
			world:request(1, "place", "shed", 2, 2, 0)
			local seen = probe.seen[#probe.seen]
			assert(seen.coins == 380 and seen.pieces == 1, `mid-yield {seen.coins} and {seen.pieces}`)
			world:leave(1)
			world.sched:advance(3)
			local data = stored(world, 1)
			assert(data.coins == 380 and #data.layout == 1, `saved {data.coins} and {#data.layout} pieces`)
			assert(data.layout[1].id == "shed")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "an autosave while the wallet yields holds the sale whole",
		run = function()
			-- Each wallet change waits 40 s, so the 60 s autosave lands inside the sell's wait.
			local world = started({ wallet = yielding(40).wallet })
			world:join(1)
			world:request(1, "place", "shed", 2, 2, 0)
			world.sched:advance(41)
			world:request(1, "sell", world:lastSync(1).pieces[1].uid) -- waits until 81
			world.sched:advance(20) -- past the autosave at 60
			assert(world:lastSync(1).coins == 380, "the sell has not finished yet")
			local data = stored(world, 1)
			assert(
				data.coins == 440 and #data.layout == 0,
				`autosaved {data.coins} and {#data.layout} pieces`
			)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "shutdown while the wallet yields waits for the sell and saves it whole",
		run = function()
			local world = started({ wallet = yielding(1).wallet })
			world:join(1)
			world:request(1, "place", "shed", 2, 2, 0)
			world.sched:advance(1)
			world:request(1, "sell", world:lastSync(1).pieces[1].uid)
			local closed = false
			world.sched:spawn(function()
				world.onClose()
				closed = true
			end)
			assert(not closed and world.records.Player_1.lease ~= nil, "close waits for the sell")
			world.sched:advance(3)
			assert(closed)
			local data = stored(world, 1)
			assert(data.coins == 440 and #data.layout == 0, `saved {data.coins} and {#data.layout} pieces`)
		end,
	},
	{
		name = "a request while the last one waits on the wallet is dropped",
		run = function()
			local world = started({ wallet = yielding(1).wallet })
			world:join(1)
			world:request(1, "place", "shed", 2, 2, 0)
			world:request(1, "place", "fence", 8, 8, 0) -- arrives during the shed's charge
			world.sched:advance(2)
			local sync = world:lastSync(1)
			assert(sync.coins == 380 and #sync.pieces == 1, `{sync.coins} coins, {#sync.pieces} pieces`)
			-- control: sent after the charge has landed, the fence goes through
			world:request(1, "place", "fence", 8, 8, 0)
			world.sched:advance(2)
			assert(world:lastSync(1).coins == 370 and #world:lastSync(1).pieces == 2)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a build call that throws is logged once with the player and the action",
		run = function()
			local world = started({
				wallet = function(_world: any, data: any): any
					local wallet = Wallet.new(data)
					return {
						balance = function()
							return wallet:balance()
						end,
						charge = function()
							error("ledger offline")
						end,
						credit = function(_self: any, amount: number, reason: string): boolean
							return wallet:credit(amount, reason)
						end,
					}
				end,
			})
			world:join(1)
			local before = #world.warnings
			world:request(1, "place", "shed", 2, 2, 0)
			local lines = {}
			for i = before + 1, #world.warnings do
				table.insert(lines, world.warnings[i])
			end
			assert(#lines == 1, `{#lines} lines`)
			for _, part in { "1", "place", "ledger offline" } do
				assert(string.find(lines[1], part, 1, true), `{part} missing from: {lines[1]}`)
			end
			local sync = world:lastSync(1)
			assert(sync.coins == 500 and #sync.pieces == 0, "no unpaid piece is left on the plot")
			world:leave(1)
			assert(#stored(world, 1).layout == 0, "or in the save")
			-- control: a refusal by the rules (too dear) logs nothing
			local plain = started()
			plain.records.Player_2 = { schema = 1, savedAt = 0, data = { coins = 5, layout = {} } }
			plain:join(2)
			local quiet = #plain.warnings
			plain:request(2, "place", "shed", 2, 2, 0)
			assert(plain:lastSync(2).coins == 5, "refused as cant_afford")
			assert(#plain.warnings == quiet, plain.warnings[#plain.warnings])
		end,
	},
	{
		name = "Sync shows the wallet's balance, not the profile's, when a game passes its own ledger",
		run = function()
			local ledgers: { [number]: number } = {}
			local function ledger(_world: any, _data: any): any
				local key = #ledgers + 1
				ledgers[key] = 2000
				return {
					balance = function()
						return ledgers[key]
					end,
					charge = function(_self: any, amount: number): boolean
						if amount > ledgers[key] then
							return false
						end
						ledgers[key] -= amount
						return true
					end,
					credit = function(_self: any, amount: number): boolean
						ledgers[key] += amount
						return true
					end,
				}
			end
			local world = FakeGame.new({ wallet = ledger })
			world:addPlot(1, PLOT_SIZE)
			world:start()
			world:join(1)
			assert(world:lastSync(1).coins == 2000, tostring(world:lastSync(1).coins))
			world:request(1, "place", "shed", 2, 2, 0)
			assert(world:lastSync(1).coins == 1880, tostring(world:lastSync(1).coins))
			-- control: a player with no plot has no build, and sees the profile's Coins
			world:join(2)
			assert(world:lastSync(2).plot == nil and world:lastSync(2).coins == 500)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "plots of different sizes all build on the smallest, with a warning",
		run = function()
			local world = FakeGame.new()
			world:addPlot(1, { 64, 1, 64 }) -- 16 by 16 cells
			world:addPlot(2, { 40, 1, 48 }) -- 10 by 12
			world:addPlot(3, { 48, 1, 40 }) -- 12 by 10
			world:start()
			local warned = 0
			for _, line in world.warnings do
				if string.find(line, "not all the same size", 1, true) then
					warned += 1
					assert(string.find(line, "10 by 10", 1, true), line)
				end
			end
			assert(warned == 1, `{warned} warnings`)
			world:join(1)
			local sync = world:lastSync(1)
			assert(sync.plot == 1 and sync.plotSize[1] == 10 and sync.plotSize[2] == 10)
			world:request(1, "place", "fence", 12, 12, 0)
			assert(#world:lastSync(1).pieces == 0, "past the shared area")
			world:request(1, "place", "fence", 8, 9, 0)
			assert(#world:lastSync(1).pieces == 1, "inside it")
			-- control: plots of one size keep their whole area, and nothing is warned
			local even = started()
			for _, line in even.warnings do
				assert(not string.find(line, "same size", 1, true), line)
			end
			even:join(1)
			assert(even:lastSync(1).plotSize[1] == 10 and even:lastSync(1).plotSize[2] == 10)
		end,
	},
	{
		name = "a restore refund the wallet refuses is logged",
		run = function()
			local world = started({
				wallet = function(_world: any, data: any): any
					local wallet = Wallet.new(data)
					return {
						balance = function()
							return wallet:balance()
						end,
						charge = function(_self: any, amount: number, reason: string): boolean
							return wallet:charge(amount, reason)
						end,
						credit = function(): boolean
							return false
						end,
					}
				end,
			})
			world.records.Player_1 = {
				schema = 1,
				savedAt = 0,
				data = { coins = 100, layout = { { id = "shed", x = 9, z = 9, r = 0 } } },
			}
			world:join(1)
			local refused = 0
			for _, line in world.warnings do
				if string.find(line, "refused the restore refund of 60", 1, true) then
					refused += 1
				end
			end
			assert(refused == 1, `{refused} lines`)
			assert(world:lastSync(1).coins == 100)
			-- control: the shipped wallet takes the refund and says so
			local ok = started()
			ok.records.Player_1 = {
				schema = 1,
				savedAt = 0,
				data = { coins = 100, layout = { { id = "shed", x = 9, z = 9, r = 0 } } },
			}
			ok:join(1)
			assert(ok:lastSync(1).coins == 160)
			for _, line in ok.warnings do
				assert(not string.find(line, "refused", 1, true), line)
			end
		end,
	},
}
