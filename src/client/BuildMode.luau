--!strict
-- Build mode: the hotbar, the ghost under the mouse, piece selection and the keys. It only draws
-- what the server last sent and reports what the player tried to do through deps.send. It never
-- changes the layout or the coins itself. Every service reaches it as an argument.
local BuildMode = {}
BuildMode.__index = BuildMode

type Def = { name: string, w: number, d: number, cost: number, maxCount: number, colour: { number } }

export type Deps = {
	theme: any,
	grid: any, -- src/shared/Grid
	layoutClass: any, -- src/shared/Layout
	parent: Instance, -- the ScreenGui
	world: Instance, -- where the ghost and the selection highlight live
	defs: { [string]: Def },
	send: (action: string, a: any?, b: any?, c: any?, d: any?) -> (),
	mouseLocation: () -> Vector2,
	camera: () -> Camera?,
	findPlot: (index: number) -> BasePart?,
	builds: () -> Instance?, -- Workspace.PaddockBuilds
	raycast: (origin: Vector3, direction: Vector3, params: RaycastParams) -> RaycastResult?,
}

type Piece = { uid: number, id: string, x: number, z: number, r: number }
type Cell = { x: number, z: number, r: number, ok: boolean }

export type BuildMode = typeof(setmetatable(
	{} :: {
		deps: Deps,
		order: { string }, -- item ids in hotbar order
		slots: { [string]: TextButton },
		hotbar: Frame,
		hint: TextLabel,
		notice: TextLabel,
		toggleButton: TextButton,
		ghost: Part,
		highlight: Highlight,
		active: boolean,
		hasPlot: boolean,
		item: string?, -- the hotbar item being placed
		rotation: number,
		selectedUid: number?,
		dragging: boolean,
		dragRotation: number,
		dragOffsetX: number, -- piece corner minus the cell grabbed, so a bare click moves nothing
		dragOffsetZ: number,
		dragLift: number, -- how far above the plot the piece was grabbed; the drag tracks that height
		coins: number,
		cellSize: number,
		plotIndex: number?,
		plotPart: BasePart?,
		layout: any?,
		pieces: { [number]: Piece },
	},
	BuildMode
))

local GHOST_HEIGHT = 0.4 -- studs
local RAY_LENGTH = 1000
local SLOT_W, SLOT_H, SLOT_GAP = 116, 52, 6
local KEYS: { Enum.KeyCode } = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
	Enum.KeyCode.Seven,
	Enum.KeyCode.Eight,
	Enum.KeyCode.Nine,
}
local HINT = "R rotate   X sell   Z undo   Q cancel   Click a piece to select, drag to move"
local NO_PLOT = "All plots are taken, you can look around"

function BuildMode.new(deps: Deps): BuildMode
	local theme = deps.theme

	-- Cheapest first, then by id, so the hotbar order never depends on table iteration order.
	local order: { string } = {}
	for id in deps.defs do
		table.insert(order, id)
	end
	table.sort(order, function(a: string, b: string): boolean
		local da, db = deps.defs[a], deps.defs[b]
		if da.cost ~= db.cost then
			return da.cost < db.cost
		end
		return a < b
	end)
	while #order > #KEYS do
		table.remove(order)
	end

	local hotbar = Instance.new("Frame")
	hotbar.Name = "Hotbar"
	hotbar.AnchorPoint = Vector2.new(0.5, 1)
	hotbar.Position = UDim2.new(0.5, 0, 1, -16)
	hotbar.Size = UDim2.fromOffset(#order * (SLOT_W + SLOT_GAP) + SLOT_GAP, SLOT_H + SLOT_GAP * 2)
	hotbar.Visible = false
	hotbar.Parent = deps.parent
	theme.style(hotbar, theme.panel)

	-- The hint sits over the world, so it gets full-strength text and a dark stroke to stay readable
	-- against bright grass and gravel.
	local hint = theme.label(deps.parent, HINT, 14, theme.text)
	hint.TextStrokeColor3 = Color3.new(0, 0, 0)
	hint.TextStrokeTransparency = 0.45
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -16 - SLOT_H - SLOT_GAP * 2 - 6)
	hint.Size = UDim2.fromOffset(640, 18)
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.Visible = false

	local notice = theme.label(deps.parent, NO_PLOT, 16, theme.text)
	notice.Name = "Notice"
	notice.AnchorPoint = Vector2.new(0.5, 0)
	notice.Position = UDim2.new(0.5, 0, 0, 16)
	notice.Size = UDim2.fromOffset(420, 32)
	notice.TextXAlignment = Enum.TextXAlignment.Center
	notice.Visible = false
	theme.style(notice, theme.panel)
	notice.BackgroundTransparency = 0

	local toggleButton = theme.button(deps.parent, "Build (B)")
	toggleButton.Name = "BuildToggle"
	toggleButton.AnchorPoint = Vector2.new(0, 1)
	toggleButton.Position = UDim2.new(0, 16, 1, -16)
	toggleButton.Size = UDim2.fromOffset(96, 36)

	local ghost = Instance.new("Part")
	ghost.Name = "PaddockGhost"
	ghost.Anchored = true
	ghost.CanCollide = false
	ghost.CanQuery = false
	ghost.CanTouch = false
	ghost.CastShadow = false
	ghost.Material = Enum.Material.SmoothPlastic
	ghost.Transparency = 1
	ghost.Parent = deps.world

	local highlight = Instance.new("Highlight")
	highlight.Name = "PaddockSelection"
	highlight.FillColor = theme.accent
	highlight.FillTransparency = 0.7
	highlight.OutlineColor = theme.accent
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	-- A Highlight with no Adornee lights up its parent, which here is the whole world, so it stays
	-- off until a piece is selected.
	highlight.Enabled = false
	highlight.Parent = deps.world

	local self = setmetatable({
		deps = deps,
		order = order,
		slots = {},
		hotbar = hotbar,
		hint = hint,
		notice = notice,
		toggleButton = toggleButton,
		ghost = ghost,
		highlight = highlight,
		active = false,
		hasPlot = false,
		item = nil,
		rotation = 0,
		selectedUid = nil,
		dragging = false,
		dragRotation = 0,
		dragOffsetX = 0,
		dragOffsetZ = 0,
		dragLift = 0,
		coins = 0,
		cellSize = 4,
		plotIndex = nil,
		plotPart = nil,
		layout = nil,
		pieces = {},
	}, BuildMode)

	for i, id in order do
		local def = deps.defs[id]
		local slot = theme.button(hotbar, "")
		slot.Name = id
		slot.Position = UDim2.fromOffset(SLOT_GAP + (i - 1) * (SLOT_W + SLOT_GAP), SLOT_GAP)
		slot.Size = UDim2.fromOffset(SLOT_W, SLOT_H)
		slot.TextSize = 14
		slot.Text = `{i}  {def.name}\n{def.cost} Coins`
		slot.Activated:Connect(function()
			self:selectItem(id)
		end)
		self.slots[id] = slot
	end

	toggleButton.Activated:Connect(function()
		self:toggle()
	end)

	self:redrawHotbar()
	return self
end

-- Slots are outlined when selected and dimmed when the balance would not cover them.
function BuildMode.redrawHotbar(self: BuildMode)
	local theme = self.deps.theme
	for id, slot in self.slots do
		local stroke = slot:FindFirstChildOfClass("UIStroke")
		if stroke ~= nil then
			stroke.Color = if self.item == id then theme.accent else theme.stroke
			stroke.Thickness = if self.item == id then 2 else theme.strokeThickness
		end
		slot.TextColor3 = if self.deps.defs[id].cost <= self.coins then theme.text else theme.muted
	end
end

function BuildMode.refreshVisibility(self: BuildMode)
	local showBar = self.active and self.hasPlot
	self.hotbar.Visible = showBar
	self.hint.Visible = showBar
	self.notice.Visible = not self.hasPlot
	if not showBar then
		self.ghost.Transparency = 1
	end
end

function BuildMode.toggle(self: BuildMode)
	if not self.hasPlot then
		return
	end
	self.active = not self.active
	if not self.active then
		self:clearSelection()
	end
	self:refreshVisibility()
end

function BuildMode.clearSelection(self: BuildMode)
	self.item = nil
	self.selectedUid = nil
	self.dragging = false
	self.highlight.Adornee = nil
	self.ghost.Transparency = 1
	self:redrawHotbar()
end

-- Picking the selected slot again puts it away.
function BuildMode.selectItem(self: BuildMode, id: string)
	if not self.active or not self.hasPlot or self.deps.defs[id] == nil then
		return
	end
	if self.item == id then
		self.item = nil
	else
		self.item = id
		self.selectedUid = nil
		self.dragging = false
		self.highlight.Adornee = nil
	end
	self:redrawHotbar()
end

-- What the server last said. The layout is rebuilt from it each time; nothing here edits it.
function BuildMode.onSync(self: BuildMode, payload: any)
	if type(payload) ~= "table" or type(payload.coins) ~= "number" then
		return
	end
	self.coins = payload.coins
	if type(payload.cellSize) == "number" and payload.cellSize > 0 then
		self.cellSize = payload.cellSize
	end

	local plot, size = payload.plot, payload.plotSize
	local hasPlot = type(plot) == "number" and type(size) == "table" and type(size[1]) == "number"
	self.hasPlot = hasPlot
	if not hasPlot then
		self.plotIndex = nil
		self.plotPart = nil
		self.layout = nil
		self.pieces = {}
		self.active = false
		self:clearSelection()
		self:refreshVisibility()
		return
	end

	if self.plotIndex ~= plot then
		self.plotIndex = plot
		self.plotPart = nil
	end
	local layout = self.deps.layoutClass.new(size[1], size[2], self.deps.defs)
	local pieces: { [number]: Piece } = {}
	if type(payload.pieces) == "table" then
		for _, piece in payload.pieces do
			local placed = layout:placeWithUid(piece.uid, piece.id, piece.x, piece.z, piece.r)
			if placed ~= nil then
				pieces[piece.uid] = placed
			end
		end
	end
	self.layout = layout
	self.pieces = pieces

	if self.selectedUid ~= nil and pieces[self.selectedUid] == nil then
		self.selectedUid = nil
		self.dragging = false
		self.highlight.Adornee = nil
	end
	self:refreshVisibility()
	self:redrawHotbar()
end

local function plotPartOf(self: BuildMode): BasePart?
	local index = self.plotIndex
	if index == nil then
		return nil
	end
	local part = self.plotPart
	if part == nil or part.Parent == nil then
		part = self.deps.findPlot(index)
		self.plotPart = part
	end
	return part
end

-- The cell under the mouse, found by meeting the mouse ray with the plot's top face, or with a
-- plane `lift` studs above it. A drag uses the height the piece was grabbed at, so grabbing a shed
-- by its roof keeps the roof under the cursor instead of the ground behind it.
local function cellUnderMouse(self: BuildMode, lift: number?): (number?, number?)
	local camera, plot = self.deps.camera(), plotPartOf(self)
	if camera == nil or plot == nil then
		return nil, nil
	end
	local m = self.deps.mouseLocation()
	local ray = camera:ViewportPointToRay(m.X, m.Y)
	local up = plot.CFrame.UpVector
	local denom = ray.Direction:Dot(up)
	if math.abs(denom) < 1e-6 then
		return nil, nil
	end
	local top = plot.CFrame.Position + up * (plot.Size.Y / 2 + (lift or 0))
	local t = (top - ray.Origin):Dot(up) / denom
	if t <= 0 then
		return nil, nil
	end
	local hit = ray.Origin + ray.Direction * t
	local _, yaw = plot.CFrame:ToOrientation()
	local grid = self.deps.grid
	local lx, lz = grid.worldToLocal(hit.X, hit.Z, plot.Position.X, plot.Position.Z, yaw)
	return grid.cellAt(lx + plot.Size.X / 2, lz + plot.Size.Z / 2, self.cellSize)
end

local function overHotbar(self: BuildMode): boolean
	if not self.hotbar.Visible then
		return false
	end
	local m = self.deps.mouseLocation()
	local p, s = self.hotbar.AbsolutePosition, self.hotbar.AbsoluteSize
	return m.X >= p.X and m.X <= p.X + s.X and m.Y >= p.Y and m.Y <= p.Y + s.Y
end

-- Whether a piece may go at a cell, from the last Sync. Placing also needs the Coins.
local function judge(self: BuildMode, id: string, x: number, z: number, r: number, moving: number?): boolean
	local layout = self.layout
	if layout == nil then
		return false
	end
	local ok = layout:canPlace(id, x, z, r, moving)
	if ok and moving == nil and self.deps.defs[id].cost > self.coins then
		return false
	end
	return ok
end

-- What the ghost is showing right now, or nil when there is nothing to place or move.
local function currentCell(self: BuildMode): (string?, Cell?)
	local id: string?, r: number, moving: number? = nil, 0, nil
	if self.dragging and self.selectedUid ~= nil then
		local piece = self.pieces[self.selectedUid]
		if piece == nil then
			return nil
		end
		id, r, moving = piece.id, self.dragRotation, piece.uid
	elseif self.item ~= nil then
		id, r = self.item, self.rotation
	else
		return nil
	end
	if id == nil or not self.active or not self.hasPlot or overHotbar(self) then
		return nil
	end
	local def = self.deps.defs[id]
	local x, z = cellUnderMouse(self, if moving ~= nil then self.dragLift else 0)
	if x == nil or z == nil then
		return nil
	end
	if moving ~= nil then
		x, z = x + self.dragOffsetX, z + self.dragOffsetZ
	else
		-- Centre a new piece's footprint on the cursor rather than hanging it off one corner.
		local fw, fd = self.deps.grid.footprint(def.w, def.d, r)
		x, z = x - math.floor(fw / 2), z - math.floor(fd / 2)
	end
	return id, { x = x, z = z, r = r, ok = judge(self, id, x, z, r, moving) }
end

-- The server's pivot maths, from Grid, so the ghost lands exactly where the model will.
local function drawGhost(self: BuildMode, id: string, cell: Cell)
	local plot = plotPartOf(self)
	if plot == nil then
		self.ghost.Transparency = 1
		return
	end
	local def = self.deps.defs[id]
	local size = plot.Size
	local ox, oy, oz, yaw =
		self.deps.grid.pivot(cell.x, cell.z, def.w, def.d, cell.r, self.cellSize, size.X, size.Y, size.Z)
	self.ghost.Size = Vector3.new(def.w * self.cellSize, GHOST_HEIGHT, def.d * self.cellSize)
	self.ghost.CFrame = plot.CFrame
		* CFrame.new(ox, oy, oz)
		* CFrame.Angles(0, yaw, 0)
		* CFrame.new(0, GHOST_HEIGHT / 2, 0)
	self.ghost.Color = if cell.ok then self.deps.theme.good else self.deps.theme.bad
	self.ghost.Transparency = 0.45
end

-- The model the server built for a uid, once it has replicated.
local function modelOf(self: BuildMode, uid: number): Instance?
	local builds = self.deps.builds()
	if builds == nil or self.plotIndex == nil then
		return nil
	end
	local folder = builds:FindFirstChild("Plot" .. self.plotIndex)
	if folder == nil then
		return nil
	end
	for _, child in folder:GetChildren() do
		if child:GetAttribute("PaddockUid") == uid then
			return child
		end
	end
	return nil
end

-- Every frame: keep the ghost on the mouse and the highlight on the selected model.
function BuildMode.tick(self: BuildMode)
	local id, cell = currentCell(self)
	if id ~= nil and cell ~= nil then
		drawGhost(self, id, cell)
	else
		self.ghost.Transparency = 1
	end
	local uid = self.selectedUid
	if uid ~= nil then
		local adornee = self.highlight.Adornee
		if adornee == nil or adornee.Parent == nil or adornee:GetAttribute("PaddockUid") ~= uid then
			self.highlight.Adornee = modelOf(self, uid)
		end
	end
	self.highlight.Enabled = uid ~= nil and self.highlight.Adornee ~= nil
end

-- The piece under the mouse, if it is on the player's own plot, and where the ray met it.
local function pieceUnderMouse(self: BuildMode): (number?, Vector3?)
	local camera, builds = self.deps.camera(), self.deps.builds()
	if camera == nil or builds == nil or self.plotIndex == nil then
		return nil
	end
	local m = self.deps.mouseLocation()
	local ray = camera:ViewportPointToRay(m.X, m.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.ghost }
	local result = self.deps.raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
	if result == nil then
		return nil
	end
	local folder = builds:FindFirstChild("Plot" .. self.plotIndex)
	local node: Instance? = result.Instance
	while node ~= nil and node ~= builds do
		local uid = node:GetAttribute("PaddockUid")
		if type(uid) == "number" and node.Parent == folder and self.pieces[uid] ~= nil then
			return uid, result.Position
		end
		node = node.Parent
	end
	return nil
end

local function finishDrag(self: BuildMode, commit: boolean)
	local uid = self.selectedUid
	local id, cell = currentCell(self)
	self.dragging = false
	if not commit or uid == nil or id == nil or cell == nil or not cell.ok then
		return
	end
	local piece = self.pieces[uid]
	if piece == nil then
		return
	end
	if cell.x == piece.x and cell.z == piece.z and cell.r == piece.r then
		return -- dropped where it started
	end
	self.deps.send("move", uid, cell.x, cell.z, cell.r)
end

local function leftClick(self: BuildMode)
	if self.item ~= nil then
		local id, cell = currentCell(self)
		if id ~= nil and cell ~= nil and cell.ok then
			self.deps.send("place", id, cell.x, cell.z, cell.r)
		end
		return
	end
	local uid, hitAt = pieceUnderMouse(self)
	if uid == nil then
		self.selectedUid = nil
		self.highlight.Adornee = nil
	elseif uid == self.selectedUid then
		local piece = self.pieces[uid] :: Piece
		local plot = plotPartOf(self)
		local lift = 0
		if plot ~= nil and hitAt ~= nil then
			local top = plot.CFrame.Position + plot.CFrame.UpVector * (plot.Size.Y / 2)
			lift = math.max(0, (hitAt - top):Dot(plot.CFrame.UpVector))
		end
		local gx, gz = cellUnderMouse(self, lift)
		if gx ~= nil and gz ~= nil then
			self.dragLift = lift
			self.dragging = true
			self.dragRotation = piece.r
			self.dragOffsetX, self.dragOffsetZ = piece.x - gx, piece.z - gz
		end
	else
		self.selectedUid = uid
		self.highlight.Adornee = modelOf(self, uid)
	end
end

-- Q steps back one level: a drag, then a selection. Not Esc: on Roblox, Esc opens the
-- system menu, which then swallows every click until it is closed.
local function cancel(self: BuildMode)
	if self.dragging then
		finishDrag(self, false)
	elseif self.item ~= nil or self.selectedUid ~= nil then
		self:clearSelection()
	end
end

function BuildMode.inputBegan(self: BuildMode, input: InputObject, processed: boolean)
	local key = input.KeyCode
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if self.active and self.hasPlot then
			leftClick(self)
		end
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if key == Enum.KeyCode.B then
		self:toggle()
	elseif not self.active or not self.hasPlot then
		return
	elseif key == Enum.KeyCode.Q then
		cancel(self)
	elseif key == Enum.KeyCode.R then
		if self.dragging then
			self.dragRotation = (self.dragRotation + 1) % 4
		elseif self.item ~= nil then
			self.rotation = (self.rotation + 1) % 4
		end
	elseif key == Enum.KeyCode.X then
		if self.selectedUid ~= nil then
			self.deps.send("sell", self.selectedUid)
			self.dragging = false
		end
	elseif key == Enum.KeyCode.Z then
		self.deps.send("undo")
	else
		for i, id in self.order do
			if KEYS[i] == key then
				self:selectItem(id)
				break
			end
		end
	end
end

function BuildMode.inputEnded(self: BuildMode, input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and self.dragging then
		finishDrag(self, true)
	end
end

return BuildMode
