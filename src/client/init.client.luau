--!strict
-- Paddock client entry. Builds the UI and talks to the server. The client never changes the layout
-- or the Coins itself: it sends what the player tried to do and redraws from the next Sync.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Paddock")
local Config = require(Shared:WaitForChild("Config"))
local Grid = require(Shared:WaitForChild("Grid"))
local Layout = require(Shared:WaitForChild("Layout"))

local Theme = require(script.Theme)
local BuildMode = require(script.BuildMode)

local localPlayer = Players.LocalPlayer
local request = Shared:WaitForChild("Request") :: RemoteEvent
local sync = Shared:WaitForChild("Sync") :: RemoteEvent

local playerGui = localPlayer:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "Paddock"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- Balance, top right. The number counts towards its new value rather than jumping.
local balanceRow = Instance.new("Frame")
balanceRow.Name = "Balance"
balanceRow.AnchorPoint = Vector2.new(1, 0)
balanceRow.Position = UDim2.new(1, -16, 0, 16)
balanceRow.Size = UDim2.fromOffset(200, 44)
balanceRow.Parent = gui
Theme.style(balanceRow, Theme.panel)

local balanceLabel = Theme.label(balanceRow, "", 18, Theme.good)
balanceLabel.FontFace = Theme.fontBold
balanceLabel.Position = UDim2.fromOffset(12, 8)
balanceLabel.Size = UDim2.new(1, -24, 0, 26)

local shown = Config.StartingCoins -- what is on screen
local target = shown -- what the server last said
balanceLabel.Text = `Coins  {shown}`

local function stepBalance()
	if shown ~= target then
		-- Move a fraction of the way, and at least 1, so a big change still finishes quickly.
		local gap = target - shown
		local move = math.max(1, math.floor(math.abs(gap) * 0.2))
		shown = if math.abs(gap) <= move then target else shown + math.sign(gap) * move
		balanceLabel.Text = `Coins  {shown}`
	end
end

local mode = BuildMode.new({
	theme = Theme,
	grid = Grid,
	layoutClass = Layout,
	parent = gui,
	world = Workspace,
	defs = Config.Placeables,
	send = function(action: string, a: any?, b: any?, c: any?, d: any?)
		request:FireServer(action, a, b, c, d)
	end,
	mouseLocation = function(): Vector2
		return UserInputService:GetMouseLocation()
	end,
	camera = function(): Camera?
		return Workspace.CurrentCamera
	end,
	findPlot = function(index: number): BasePart?
		for _, instance in CollectionService:GetTagged("PaddockPlot") do
			if instance:IsA("BasePart") and instance:GetAttribute("PlotIndex") == index then
				return instance
			end
		end
		return nil
	end,
	builds = function(): Instance?
		return Workspace:FindFirstChild("PaddockBuilds")
	end,
	raycast = function(origin: Vector3, direction: Vector3, params: RaycastParams): RaycastResult?
		return Workspace:Raycast(origin, direction, params)
	end,
})

sync.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" or type(payload.coins) ~= "number" then
		return
	end
	target = payload.coins
	mode:onSync(payload)
end)

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	mode:inputBegan(input, processed)
end)
UserInputService.InputEnded:Connect(function(input: InputObject, _processed: boolean)
	mode:inputEnded(input)
end)

RunService.RenderStepped:Connect(function()
	mode:tick()
end)
RunService.Heartbeat:Connect(stepBalance)
