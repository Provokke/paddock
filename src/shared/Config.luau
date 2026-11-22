--!strict
return table.freeze({
	DataStoreName = "PaddockPlayerData_v1", -- change it and every player starts fresh
	SchemaVersion = 1, -- bump when the saved data shape changes, and add a migration step
	AutosaveSeconds = 60, -- how often each session is written
	LeaseSeconds = 180, -- must be well over AutosaveSeconds, or a busy server loses its own lock
	LoadRetries = 5, -- attempts to load a profile before giving up
	RetryBaseSeconds = 1, -- doubles each retry: 1, 2, 4, 8 (five attempts, four waits)
	CloseTimeoutSeconds = 25, -- BindToClose gets about 30 s in total, leave headroom
	CellSize = 4, -- studs per grid cell
	StartingCoins = 500, -- what a new player's profile starts with
	SellRefund = 0.5, -- share of the cost handed back when a piece is sold
	UndoDepth = 10, -- how many placements a player can step back through
	UndoSeconds = 30, -- how long a placement stays undoable
	-- id -> piece. w and d are the footprint in cells, cost is in Coins, maxCount caps how many
	-- of that piece one paddock can hold, and colour is {r, g, b} for the placeholder part.
	Placeables = table.freeze({
		fence = table.freeze({
			name = "Fence",
			w = 2,
			d = 1,
			cost = 10,
			maxCount = 40,
			colour = { 150, 105, 60 },
		}),
		hay_bale = table.freeze({
			name = "Hay Bale",
			w = 1,
			d = 1,
			cost = 15,
			maxCount = 20,
			colour = { 220, 190, 90 },
		}),
		trough = table.freeze({
			name = "Water Trough",
			w = 2,
			d = 1,
			cost = 40,
			maxCount = 6,
			colour = { 110, 140, 170 },
		}),
		tree = table.freeze({
			name = "Shade Tree",
			w = 1,
			d = 1,
			cost = 25,
			maxCount = 12,
			colour = { 70, 130, 60 },
		}),
		path = table.freeze({
			name = "Gravel Path",
			w = 1,
			d = 1,
			cost = 5,
			maxCount = 60,
			colour = { 170, 160, 145 },
		}),
		shed = table.freeze({
			name = "Tool Shed",
			w = 3,
			d = 2,
			cost = 120,
			maxCount = 2,
			colour = { 170, 70, 55 },
		}),
	}),
	Limits = table.freeze({ BurstPerPlayer = 8, RefillPerSecond = 4 }), -- remote rate limit per player
})
