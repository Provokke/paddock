--!strict
-- The pieces on one plot and the rules for where they may go. Pure data: it knows nothing about
-- players, Coins or parts. Every failing call leaves the layout exactly as it was, because each
-- one finishes all its checks before it writes anything.
local Layout = {}
Layout.__index = Layout

export type Def = { w: number, d: number, maxCount: number }
export type Piece = { uid: number, id: string, x: number, z: number, r: number }

export type Layout = typeof(setmetatable(
	{} :: {
		width: number,
		depth: number,
		defs: { [string]: Def },
		live: { [number]: Piece },
		occupied: { [string]: number }, -- "x,z" -> uid
		nextUid: number,
	},
	Layout
))

local function key(x: number, z: number): string
	return x .. "," .. z
end

local function copyPiece(p: Piece): Piece
	return { uid = p.uid, id = p.id, x = p.x, z = p.z, r = p.r }
end

-- Footprint size after rotation. Odd turns swap width and depth.
local function size(def: Def, r: number): (number, number)
	if r % 2 == 1 then
		return def.d, def.w
	end
	return def.w, def.d
end

function Layout.new(width: number, depth: number, defs: { [string]: Def }): Layout
	return setmetatable({
		width = width,
		depth = depth,
		defs = defs,
		live = {},
		occupied = {},
		nextUid = 1,
	}, Layout)
end

function Layout.canPlace(
	self: Layout,
	id: string,
	x: number,
	z: number,
	r: number,
	ignoreUid: number?
): (boolean, string?)
	local def = self.defs[id]
	if def == nil then
		return false, "unknown_item"
	end
	if r ~= 0 and r ~= 1 and r ~= 2 and r ~= 3 then
		return false, "bad_rotation"
	end
	local fw, fd = size(def, r)
	if x ~= math.floor(x) or z ~= math.floor(z) then
		return false, "out_of_bounds"
	end
	if x < 0 or z < 0 or x + fw > self.width or z + fd > self.depth then
		return false, "out_of_bounds"
	end
	for cx = x, x + fw - 1 do
		for cz = z, z + fd - 1 do
			local other = self.occupied[key(cx, cz)]
			if other ~= nil and other ~= ignoreUid then
				return false, "overlap"
			end
		end
	end
	local held = 0
	for uid, piece in self.live do
		if piece.id == id and uid ~= ignoreUid then
			held += 1
		end
	end
	if held >= def.maxCount then
		return false, "limit"
	end
	return true, nil
end

local function occupy(self: Layout, piece: Piece)
	local fw, fd = size(self.defs[piece.id], piece.r)
	for cx = piece.x, piece.x + fw - 1 do
		for cz = piece.z, piece.z + fd - 1 do
			self.occupied[key(cx, cz)] = piece.uid
		end
	end
end

local function vacate(self: Layout, piece: Piece)
	local fw, fd = size(self.defs[piece.id], piece.r)
	for cx = piece.x, piece.x + fw - 1 do
		for cz = piece.z, piece.z + fd - 1 do
			self.occupied[key(cx, cz)] = nil
		end
	end
end

function Layout.place(self: Layout, id: string, x: number, z: number, r: number): (Piece?, string?)
	local ok, why = self:canPlace(id, x, z, r)
	if not ok then
		return nil, why
	end
	local piece: Piece = { uid = self.nextUid, id = id, x = x, z = z, r = r }
	self.nextUid += 1
	self.live[piece.uid] = piece
	occupy(self, piece)
	return copyPiece(piece), nil
end

-- For undo: puts a sold piece back under its old uid. nextUid moves past it so a fresh place can
-- never be handed the same uid.
function Layout.placeWithUid(
	self: Layout,
	uid: number,
	id: string,
	x: number,
	z: number,
	r: number
): (Piece?, string?)
	if self.live[uid] ~= nil then
		return nil, "uid_taken"
	end
	local ok, why = self:canPlace(id, x, z, r)
	if not ok then
		return nil, why
	end
	local piece: Piece = { uid = uid, id = id, x = x, z = z, r = r }
	self.live[uid] = piece
	occupy(self, piece)
	if uid >= self.nextUid then
		self.nextUid = uid + 1
	end
	return copyPiece(piece), nil
end

function Layout.move(self: Layout, uid: number, x: number, z: number, r: number): (boolean, string?)
	local piece = self.live[uid]
	if piece == nil then
		return false, "no_piece"
	end
	local ok, why = self:canPlace(piece.id, x, z, r, uid)
	if not ok then
		return false, why
	end
	vacate(self, piece)
	piece.x, piece.z, piece.r = x, z, r
	occupy(self, piece)
	return true, nil
end

function Layout.remove(self: Layout, uid: number): Piece?
	local piece = self.live[uid]
	if piece == nil then
		return nil
	end
	vacate(self, piece)
	self.live[uid] = nil
	return copyPiece(piece)
end

function Layout.get(self: Layout, uid: number): Piece?
	local piece = self.live[uid]
	if piece == nil then
		return nil
	end
	return copyPiece(piece)
end

function Layout.count(self: Layout, id: string): number
	local n = 0
	for _, piece in self.live do
		if piece.id == id then
			n += 1
		end
	end
	return n
end

function Layout.pieces(self: Layout): { Piece }
	local list = {}
	for _, piece in self.live do
		table.insert(list, copyPiece(piece))
	end
	table.sort(list, function(a, b)
		return a.uid < b.uid
	end)
	return list
end

return Layout
