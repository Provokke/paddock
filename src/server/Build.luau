--!strict
-- Place, move, sell and undo for one plot. This is the money path, so each call finishes every
-- check before it writes, and nothing in here yields. The layout, wallet and defs come in through
-- deps.
--
-- Re-entrancy: a wallet (or its onChange) might yield, and another call could then run. So the
-- state that guards a payout (the piece, the history entry) is committed before any wallet call,
-- and rolled back if the wallet refuses. A second call then finds the guard already gone.
--
-- Every reason Build can return:
--   place: unknown_item, bad_rotation, out_of_bounds, overlap, limit (from the layout or the
--          defs), cant_afford (the charge was refused)
--   move:  no_piece, plus the layout's reasons
--   sell:  no_piece, unknown_item, wallet_refused (the credit was refused and the sale rolled back)
--   undo:  nothing, expired, no_piece, cant_afford, wallet_refused, uid_taken (the old uid is live
--          again), plus the layout's reasons (overlap, out_of_bounds, limit, unknown_item,
--          bad_rotation)
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

-- A game may pass its own ledger instead of a Wallet. Keep in step with WalletLike in Wallet.luau.
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

-- A refused credit-back means the wallet broke its contract (it took a charge and would not give
-- the same whole amount back), so this is loud rather than silent.
local function mustCredit(wallet: WalletLike, amount: number, reason: string)
	if not wallet:credit(amount, reason) then
		error(`wallet refused a credit of {amount} Coins ({reason}); it has broken its contract`)
	end
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Build.new(deps: Deps): Build
	assert(
		finite(deps.sellRefund) and deps.sellRefund >= 0 and deps.sellRefund <= 1,
		"sellRefund must be a number from 0 to 1"
	)
	assert(
		finite(deps.undoDepth) and deps.undoDepth >= 0 and deps.undoDepth == math.floor(deps.undoDepth),
		"undoDepth must be a whole number, 0 or more"
	)
	assert(finite(deps.undoSeconds) and deps.undoSeconds >= 0, "undoSeconds must be a number, 0 or more")
	return setmetatable({ deps = deps, history = {} }, Build)
end

local function push(self: Build, entry: Entry)
	table.insert(self.history, entry)
	while #self.history > self.deps.undoDepth do
		table.remove(self.history, 1)
	end
end

-- canPlace, then charge, then place. If a charge yields and a second place gets through canPlace
-- meanwhile, the second place fails after its charge and is credited back, so nothing is minted.
function Build.place(self: Build, id: string, x: number, z: number, r: number): (Piece?, string?)
	local deps = self.deps
	local ok, why = deps.layout:canPlace(id, x, z, r)
	if not ok then
		return nil, why
	end
	local def = deps.defs[id]
	if def == nil then
		return nil, "unknown_item"
	end
	local cost = def.cost
	if not deps.wallet:charge(cost, "place " .. id) then
		return nil, "cant_afford"
	end
	local piece, placeWhy = deps.layout:place(id, x, z, r)
	if piece == nil then
		mustCredit(deps.wallet, cost, "place failed " .. id)
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

-- The piece goes first, then the payout; a refused payout puts the piece back.
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
	deps.layout:remove(uid)
	if not deps.wallet:credit(refund, "sell " .. piece.id) then
		local back, why = deps.layout:placeWithUid(piece.uid, piece.id, piece.x, piece.z, piece.r)
		if back == nil then
			error(`could not restore sold piece {uid} after a refused credit: {tostring(why)}`)
		end
		return nil, "wallet_refused"
	end
	push(self, { kind = "sell", at = deps.now(), uid = uid, charged = 0, refunded = refund, piece = piece })
	return refund, nil
end

-- Reverses the newest action. Every refusal leaves the balance and the layout as they were. The
-- entry is popped before any wallet call so a second undo cannot reach it, and pushed back if the
-- undo is refused. Expired entries are dropped with everything older; so is one whose piece has
-- gone (no_piece), since it can never succeed.
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
	table.remove(history)

	local layout, wallet = deps.layout, deps.wallet
	local function refuse(why: string?): (string?, string?)
		table.insert(history, entry)
		return nil, why
	end

	if entry.kind == "place" then
		local piece = layout:get(entry.uid)
		if piece == nil then
			return nil, "no_piece"
		end
		layout:remove(entry.uid)
		if not wallet:credit(entry.charged, "undo place") then
			local back, why = layout:placeWithUid(piece.uid, piece.id, piece.x, piece.z, piece.r)
			if back == nil then
				error(`could not restore piece {entry.uid} after a refused credit: {tostring(why)}`)
			end
			return refuse("wallet_refused")
		end
	elseif entry.kind == "move" then
		local old = entry.piece :: Piece
		local ok, why = layout:move(entry.uid, old.x, old.z, old.r)
		if not ok then
			if why == "no_piece" then
				return nil, why
			end
			return refuse(why)
		end
	else
		local old = entry.piece :: Piece
		if layout:get(old.uid) ~= nil then
			return refuse("uid_taken")
		end
		local fits, fitWhy = layout:canPlace(old.id, old.x, old.z, old.r)
		if not fits then
			return refuse(fitWhy)
		end
		if not wallet:charge(entry.refunded, "undo sell") then
			return refuse("cant_afford")
		end
		local back, why = layout:placeWithUid(old.uid, old.id, old.x, old.z, old.r)
		if back == nil then
			mustCredit(wallet, entry.refunded, "undo sell failed")
			return refuse(why)
		end
	end
	return entry.kind, nil
end

function Build.snapshot(self: Build): { coins: number, pieces: { Piece } }
	return { coins = self.deps.wallet:balance(), pieces = self.deps.layout:pieces() }
end

return Build
