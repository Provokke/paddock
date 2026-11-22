--!strict
-- Paddock server entry. This is where services, remotes, the DataStore, plots and models are
-- touched. The rules themselves live in the modules next to it and are covered by the Lune tests.
local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Paddock")
local Config = require(Shared:WaitForChild("Config"))
local ConfigCheck = require(Shared:WaitForChild("ConfigCheck"))
local Grid = require(Shared:WaitForChild("Grid"))
local Layout = require(Shared:WaitForChild("Layout"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))
local Validate = require(Shared:WaitForChild("Validate"))

local Build = require(script.Build)
local Handlers = require(script.Handlers)
local Lease = require(script.Data.Lease)
local MemoryStore = require(script.Data.MemoryStore)
local Migrations = require(script.Data.Migrations)
local Plots = require(script.Plots)
local Profile = require(script.Data.Profile)
local Restore = require(script.Restore)
local Sessions = require(script.Sessions)
local Steps = require(script.Data.Steps)
local Store = require(script.Data.Store)
local Wallet = require(script.Wallet)

local configOk, configProblem = ConfigCheck.check(Config)
if not configOk then
	warn("[Paddock] config problem: " .. tostring(configProblem))
	warn("[Paddock] not starting until the config is fixed.")
	return
end

local PLOT_TAG = "PaddockPlot"
local PIECE_HEIGHT = 2 -- studs, for the placeholder box

-- Data store. Studio uses an in-memory table unless ServerStorage has PaddockUseDataStore = true.
local useRealStore = not RunService:IsStudio() or ServerStorage:GetAttribute("PaddockUseDataStore") == true
local dataStore: any
if useRealStore then
	dataStore = DataStoreService:GetDataStore(Config.DataStoreName)
else
	dataStore = MemoryStore.new()
	print(
		"[Paddock] Studio: using an in-memory store. Set ServerStorage attribute PaddockUseDataStore to use the real one."
	)
end

-- Every Studio play test gets its own id, so a lease left behind by a crashed or parallel test
-- reads as someone else's (and runs out) rather than as ours.
local jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local function log(message: string)
	warn("[Paddock] " .. message)
end

local profile = Profile.new({ startingCoins = Config.StartingCoins })

local store = Store.new({
	dataStore = dataStore,
	lease = Lease,
	migrations = Migrations,
	clock = os.time,
	wait = task.wait,
	budget = function(_kind: string): number
		if not useRealStore then
			return 100 -- the in-memory store has no request budget
		end
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end,
	jobId = jobId,
	nonce = function(): string
		return HttpService:GenerateGUID(false)
	end,
	resume = function(thread: thread)
		task.spawn(thread)
	end,
	leaseSeconds = Config.LeaseSeconds,
	retries = Config.LoadRetries,
	retryBase = Config.RetryBaseSeconds,
	schema = Config.SchemaVersion,
	steps = Steps,
	defaultData = profile.defaultData,
	encode = profile.encode,
	decode = profile.decode,
	log = log,
})

-- Remotes. Request is client to server (intent only); Sync is server to client.
local request = Instance.new("RemoteEvent")
request.Name = "Request"
request.Parent = Shared
local sync = Instance.new("RemoteEvent")
sync.Name = "Sync"
sync.Parent = Shared

-- Plots: parts tagged PaddockPlot with a whole PlotIndex attribute. A plot too small for one cell
-- is left out, as every piece a player had would count as out of bounds.
local plotParts: { [number]: BasePart } = {}
local plotCells: { [number]: { w: number, d: number } } = {}
for _, instance in CollectionService:GetTagged(PLOT_TAG) do
	local index = instance:GetAttribute("PlotIndex")
	if not instance:IsA("BasePart") then
		log(`{instance.Name} is tagged {PLOT_TAG} but is not a BasePart, so it is not a plot`)
	elseif not Validate.isInteger(index, 1, 2 ^ 31) then
		log(`{instance.Name} has no whole PlotIndex of 1 or more, so it is not a plot`)
	elseif plotParts[index] ~= nil then
		log(`{instance.Name} repeats PlotIndex {index}, so it is not used`)
	else
		local size = instance.Size
		local w = math.floor(size.X / Config.CellSize)
		local d = math.floor(size.Z / Config.CellSize)
		if w < 1 or d < 1 then
			log(`{instance.Name} is smaller than one cell, so it is not used`)
		else
			plotParts[index] = instance
			plotCells[index] = { w = w, d = d }
		end
	end
end
local plotIndices: { number } = {}
for index in plotParts do
	table.insert(plotIndices, index)
end
if #plotIndices == 0 then
	warn(
		`[Paddock] no part is tagged {PLOT_TAG}, so nobody can build yet. Tag a part and give it a PlotIndex.`
	)
end
local plots = Plots.new(plotIndices)

local buildsFolder = Instance.new("Folder")
buildsFolder.Name = "PaddockBuilds"
buildsFolder.Parent = Workspace

-- What the server keeps for each player on a plot.
type PieceModel = { model: Instance, id: string, x: number, z: number, r: number }
type State = {
	session: any,
	plot: number?,
	layout: any?,
	build: any?, -- nil unless the session can be saved
	folder: Instance?,
	models: { [number]: PieceModel },
}
local states: { [number]: State } = {}

local sessions: any
local handlers: any

-- The layout goes back into the session data as { id, x, z, r } entries, so the next save holds
-- it with the coins.
local function writeLayout(state: State)
	local layout = state.layout
	if layout == nil then
		return
	end
	local out = {}
	for _, piece in layout:pieces() do
		table.insert(out, { id = piece.id, x = piece.x, z = piece.z, r = piece.r })
	end
	state.session.data.layout = out
end

-- One piece's model: the template from ReplicatedStorage.PaddockPieces if there is one, else an
-- anchored box of the footprint in the item's colour.
local function makeModel(state: State, uid: number, piece: any)
	local index = state.plot :: number
	local part = plotParts[index]
	local def = Config.Placeables[piece.id]
	local cell = Config.CellSize
	local size = part.Size
	local fw, fd = Grid.footprint(def.w, def.d, piece.r)
	local cx, cz = Grid.centre(piece.x, piece.z, fw, fd, cell)
	local pivot = part.CFrame
		* CFrame.new(-size.X / 2 + cx, size.Y / 2, -size.Z / 2 + cz)
		* CFrame.Angles(0, piece.r * math.pi / 2, 0)

	local template = nil
	local pieces = ReplicatedStorage:FindFirstChild("PaddockPieces")
	if pieces ~= nil then
		template = pieces:FindFirstChild(piece.id)
	end
	local model: Instance
	if template ~= nil and template:IsA("Model") then
		local copy = template:Clone()
		for _, descendant in copy:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
			end
		end
		copy:PivotTo(pivot)
		model = copy
	else
		local box = Instance.new("Part")
		box.Anchored = true
		box.Size = Vector3.new(def.w * cell, PIECE_HEIGHT, def.d * cell)
		local c = def.colour
		box.Color = Color3.fromRGB(c[1], c[2], c[3])
		box:PivotTo(pivot * CFrame.new(0, PIECE_HEIGHT / 2, 0)) -- sits on the plot's top face
		model = box
	end
	model.Name = piece.id
	model:SetAttribute("PaddockUid", uid)
	model.Parent = state.folder
	state.models[uid] = { model = model, id = piece.id, x = piece.x, z = piece.z, r = piece.r }
end

-- Brings the models in line with the layout, rebuilding only the pieces that changed.
local function refreshModels(state: State)
	local layout = state.layout
	if layout == nil or state.folder == nil then
		return
	end
	local live: { [number]: any } = {}
	for _, piece in layout:pieces() do
		live[piece.uid] = piece
	end
	for uid, made in state.models do
		local piece = live[uid]
		if
			piece == nil
			or piece.id ~= made.id
			or piece.x ~= made.x
			or piece.z ~= made.z
			or piece.r ~= made.r
		then
			made.model:Destroy()
			state.models[uid] = nil
		end
	end
	for uid, piece in live do
		if state.models[uid] == nil then
			makeModel(state, uid, piece)
		end
	end
end

-- What one player sees. Sent after every build call and on join.
local function syncPlayer(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	local session = sessions:get(userId)
	local state = states[userId]
	if player == nil or session == nil or state == nil then
		return
	end
	if state.build ~= nil and sessions:writableSession(userId) == state.session then
		writeLayout(state)
	end
	refreshModels(state)
	local payload: { [string]: any } = {
		coins = session.data.coins,
		pieces = if state.layout ~= nil then state.layout:pieces() else {},
		cellSize = Config.CellSize,
	}
	if state.plot ~= nil then
		local cells = plotCells[state.plot]
		payload.plot = state.plot
		payload.plotSize = { cells.w, cells.d }
	end
	sync:FireClient(player, payload)
end

-- A session went live: claim a plot, bring back the saved layout, show it.
local function onSessionReady(userId: number, session: any)
	local state: State =
		{ session = session, plot = nil, layout = nil, build = nil, folder = nil, models = {} }
	states[userId] = state
	local index = plots:claim(userId)
	if index ~= nil then
		local cells = plotCells[index]
		local layout = Layout.new(cells.w, cells.d, Config.Placeables)
		local result = Restore.run(session.data.layout, layout, Config.Placeables, Config.SellRefund)
		state.plot = index
		state.layout = layout
		local folder = Instance.new("Folder")
		folder.Name = "Plot" .. index
		folder.Parent = buildsFolder
		state.folder = folder
		-- A view-only session shows what was saved but changes nothing: no refund, no write-back.
		if sessions:writableSession(userId) == session then
			local wallet = Wallet.new(session.data)
			if result.refund > 0 then
				wallet:credit(result.refund, "restore refund")
			end
			if #result.dropped > 0 then
				log(
					`{#result.dropped} saved pieces for {userId} no longer fit and were refunded {result.refund} Coins`
				)
			end
			writeLayout(state)
			state.build = Build.new({
				layout = layout,
				wallet = wallet,
				defs = Config.Placeables,
				sellRefund = Config.SellRefund,
				undoDepth = Config.UndoDepth,
				undoSeconds = Config.UndoSeconds,
				now = os.clock,
			})
		end
	end
	syncPlayer(userId)
end

sessions = Sessions.new({
	store = store,
	keyFor = function(userId: number): string
		return "Player_" .. userId
	end,
	present = function(player: any): boolean
		return player.Parent ~= nil
	end,
	kick = function(player: any, message: string)
		player:Kick(message)
	end,
	playerOf = function(userId: number): any
		return Players:GetPlayerByUserId(userId)
	end,
	ready = onSessionReady,
	spawn = function(fn: () -> ())
		task.spawn(fn)
	end,
	wait = function(seconds: number)
		task.wait(seconds)
	end,
	clock = os.clock,
	closeSeconds = Config.CloseTimeoutSeconds,
	log = log,
})

handlers = Handlers.new({
	validate = Validate,
	limiter = RateLimiter.new(Config.Limits.BurstPerPlayer, Config.Limits.RefillPerSecond, os.clock),
	buildFor = function(userId: number): any
		-- Only a session that would be saved may change anything. A player with no plot, or a
		-- view-only or lost session, has no build.
		local state = states[userId]
		if state == nil or state.build == nil or sessions:writableSession(userId) ~= state.session then
			return nil
		end
		return state.build
	end,
	sync = syncPlayer,
})

request.OnServerEvent:Connect(function(player: Player, action: any, a: any, b: any, c: any, d: any)
	local ok, err = pcall(function()
		handlers:handle(player.UserId, action, a, b, c, d)
	end)
	if not ok then
		log("request error: " .. tostring(err))
	end
end)

-- Sessions
local function onPlayerAdded(player: Player)
	sessions:join(player.UserId, player)
end

local function onPlayerRemoving(player: Player)
	local userId = player.UserId
	handlers.deps.limiter:forget(userId)
	local state = states[userId]
	states[userId] = nil
	if state ~= nil and state.folder ~= nil then
		state.folder:Destroy()
	end
	plots:release(userId)
	sessions:leave(userId)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- Autosave. A session that has lost its lease is kicked rather than allowed to carry on unsaved.
task.spawn(function()
	while true do
		task.wait(Config.AutosaveSeconds)
		sessions:saveAll()
	end
end)

-- Releases every session and waits for loads and releases still running, within the timeout.
game:BindToClose(function()
	sessions:close()
end)
