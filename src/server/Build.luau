--!strict
-- Place, move, sell and undo for one plot. This is the money path, so each call finishes every
-- check before it writes, and nothing in here yields: the balance cannot change between a check
-- and its commit. The layout, wallet and defs come in through deps.
local Build = {}
Build.__index = Build

export type Piece = { uid: number, id: string, x: number, z: number, r: number }

-- The parts of Layout that Build uses. Layout itself is passed in by the caller.
export type LayoutLike = {
	canPlace: (LayoutLike, string, number, number, number, number?) -> (boolean, string?),
	place: (LayoutLike, string, number, number, number) -> (Piece?, string?),
	placeWithUid: (LayoutLike, number, string, number, number, number) -> (Piece?, string?),
	move: (LayoutLike, number, number, number, number) -> (boolean, string?),
	remove: (LayoutLike, number) -> Piece?,
	get: (LayoutLike, number) -> Piece?,
	pieces: (LayoutLike) -> { Piece },
}

-- A game may pass its own ledger instead of a Wallet.
export type WalletLike = {
	balance: (WalletLike) -> number,
	charge: (WalletLike, number, string) -> boolean,
	credit: (WalletLike, number, string) -> boolean,
}

export type Deps = {
	layout: LayoutLike,
	wallet: WalletLike,
	defs: { [string]: { cost: number } },
	sellRefund: number,
	undoDepth: number,
	undoSeconds: number,
	now: () -> number,
}

-- What an undo needs to reverse one action. The amounts are what was actually charged or paid,
-- never a fresh catalogue lookup, so a price change cannot mint or burn Coins.
type Entry = {
	kind: "place" | "move" | "sell",
	at: number,
	uid: number,
	charged: number, -- place: Coins charged
	refunded: number, -- sell: Coins paid out
	piece: Piece?, -- sell: the piece as it was; move: where it was
}

export type Build = typeof(setmetatable(
	{} :: {
		deps: Deps,
		history: { Entry },
	},
	Build
))

function Build.new(deps: Deps): Build
	return setmetatable({ deps = deps, history = {} }, Build)
end

local function push(self: Build, entry: Entry)
	table.insert(self.history, entry)
	while #self.history > self.deps.undoDepth do
		table.remove(self.history, 1)
	end
end

function Build.place(self: Build, id: string, x: number, z: number, r: number): (Piece?, string?)
	local deps = self.deps
	local ok, why = deps.layout:canPlace(id, x, z, r)
	if not ok then
		return nil, why
	end
	local cost = deps.defs[id].cost
	if not deps.wallet:charge(cost, "place " .. id) then
		return nil, "cant_afford"
	end
	local piece, placeWhy = deps.layout:place(id, x, z, r)
	if piece == nil then
		-- canPlace just passed and nothing can have run since, so this should not happen. If it
		-- does, the player gets their Coins back.
		deps.wallet:credit(cost, "place failed " .. id)
		return nil, placeWhy
	end
	push(
		self,
		{ kind = "place", at = deps.now(), uid = piece.uid, charged = cost, refunded = 0, piece = nil }
	)
	return piece, nil
end

function Build.move(self: Build, uid: number, x: number, z: number, r: number): (boolean, string?)
	local layout = self.deps.layout
	local old = layout:get(uid)
	if old == nil then
		return false, "no_piece"
	end
	local ok, why = layout:move(uid, x, z, r)
	if not ok then
		return false, why
	end
	push(self, { kind = "move", at = self.deps.now(), uid = uid, charged = 0, refunded = 0, piece = old })
	return true, nil
end

function Build.sell(self: Build, uid: number): (number?, string?)
	local deps = self.deps
	local piece = deps.layout:get(uid)
	if piece == nil then
		return nil, "no_piece"
	end
	local def = deps.defs[piece.id]
	if def == nil then
		return nil, "unknown_item"
	end
	local refund = math.floor(def.cost * deps.sellRefund)
	-- Pay first: if the wallet refuses, the piece stays and nothing has changed.
	if not deps.wallet:credit(refund, "sell " .. piece.id) then
		return nil, "wallet_refused"
	end
	deps.layout:remove(uid)
	push(self, { kind = "sell", at = deps.now(), uid = uid, charged = 0, refunded = refund, piece = piece })
	return refund, nil
end

-- Reverses the newest action. Every refusal leaves the balance and the layout as they were. An
-- expired entry is dropped along with everything older; any other refusal keeps the entry.
function Build.undo(self: Build): (string?, string?)
	local deps = self.deps
	local history = self.history
	local entry = history[#history]
	if entry == nil then
		return nil, "nothing"
	end
	if deps.now() - entry.at > deps.undoSeconds then
		table.clear(history)
		return nil, "expired"
	end

	local layout, wallet = deps.layout, deps.wallet
	if entry.kind == "place" then
		if layout:get(entry.uid) == nil then
			return nil, "no_piece"
		end
		if not wallet:credit(entry.charged, "undo place") then
			return nil, "wallet_refused"
		end
		layout:remove(entry.uid)
	elseif entry.kind == "move" then
		local old = entry.piece :: Piece
		local ok, why = layout:move(entry.uid, old.x, old.z, old.r)
		if not ok then
			return nil, why
		end
	else
		local old = entry.piece :: Piece
		if not wallet:charge(entry.refunded, "undo sell") then
			return nil, "cant_afford"
		end
		local back, why = layout:placeWithUid(old.uid, old.id, old.x, old.z, old.r)
		if back == nil then
			wallet:credit(entry.refunded, "undo sell failed")
			return nil, why
		end
	end
	table.remove(history)
	return entry.kind, nil
end

function Build.snapshot(self: Build): { coins: number, pieces: { Piece } }
	return { coins = self.deps.wallet:balance(), pieces = self.deps.layout:pieces() }
end

return Build
