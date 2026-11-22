--!strict
-- Place, move, sell and undo for one plot. This is the money path, so each call finishes every
-- check before it writes, and nothing in here yields. The layout, wallet and defs come in through
-- deps.
--
-- Commit first, pay second: every call changes the layout before it calls the wallet, reports the
-- change through `commit` (the entry script writes the layout into the session data there), and
-- if the wallet refuses, rolls the layout back and commits again. So a save made while a wallet
-- call is waiting holds the new layout. With a wallet that writes its balance before it yields,
-- as Wallet does (its onChange runs after the write), that save holds both halves of the action.
--
-- Re-entrancy: a wallet (or its onChange) might yield, and another call could then run. The entry
-- script stops that with a per-player busy guard in Handlers, but Build does not rely on it. The
-- state that guards a payout (the piece, the history entry) is committed before any wallet call,
-- so a second call finds the guard already gone. A piece that is placed but not yet paid for is
-- marked pending, and nothing can sell, move or undo it until its charge has landed.
--
-- Every reason Build can return:
--   place: unknown_item, bad_rotation, out_of_bounds, overlap, limit (from the layout or the
--          defs), cant_afford (the charge was refused and the piece taken off again)
--   move:  no_piece, busy (the piece is waiting on its charge), plus the layout's reasons
--   sell:  no_piece, busy, unknown_item, wallet_refused (the credit was refused and the sale
--          rolled back)
--   undo:  nothing, expired, no_piece, busy, cant_afford, wallet_refused, uid_taken (the old uid
--          is live again), plus the layout's reasons (overlap, out_of_bounds, limit, unknown_item,
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
	-- Called each time the layout changes: before any wallet call, and again after a rollback.
	commit: (() -> ())?,
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
		pending: { [number]: boolean }, -- uids placed whose charge has not landed yet
	},
	Build
))

local function commit(deps: Deps)
	local callback = deps.commit
	if callback ~= nil then
		callback()
	end
end

-- Charges for a piece that is already in the layout. The piece is pending (nothing can sell,
-- move or undo it) and committed while the wallet runs. If the charge is refused, or the wallet
-- throws, the piece comes off again and that is committed too, so a broken wallet can never leave
-- a piece that was not paid for. Returns whether it was paid, and the error if the wallet threw.
local function chargeFor(self: Build, uid: number, amount: number, reason: string): (boolean, any)
	local deps = self.deps
	self.pending[uid] = true
	commit(deps)
	local called, paid = pcall(deps.wallet.charge, deps.wallet, amount, reason)
	self.pending[uid] = nil
	if called and paid then
		return true, nil
	end
	deps.layout:remove(uid)
	commit(deps)
	return false, if called then nil else paid
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
	return setmetatable({ deps = deps, history = {}, pending = {} }, Build)
end

local function push(self: Build, entry: Entry)
	table.insert(self.history, entry)
	while #self.history > self.deps.undoDepth do
		table.remove(self.history, 1)
	end
end

-- Check, commit, then charge. The piece is placed and committed first, so a save made during the
-- charge never holds the Coins taken without the piece. If the charge is refused the piece comes
-- off again. Its uid is spent, which is harmless, as uids only ever count up.
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
	local piece, placeWhy = deps.layout:place(id, x, z, r)
	if piece == nil then
		return nil, placeWhy
	end
	local paid, err = chargeFor(self, piece.uid, cost, "place " .. id)
	if err ~= nil then
		error(err, 0)
	elseif not paid then
		return nil, "cant_afford"
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
	if self.pending[uid] then
		return false, "busy"
	end
	local ok, why = layout:move(uid, x, z, r)
	if not ok then
		return false, why
	end
	commit(self.deps)
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
	if self.pending[uid] then
		return nil, "busy"
	end
	local def = deps.defs[piece.id]
	if def == nil then
		return nil, "unknown_item"
	end
	local refund = math.floor(def.cost * deps.sellRefund)
	deps.layout:remove(uid)
	commit(deps)
	if not deps.wallet:credit(refund, "sell " .. piece.id) then
		local back, why = deps.layout:placeWithUid(piece.uid, piece.id, piece.x, piece.z, piece.r)
		if back == nil then
			error(`could not restore sold piece {uid} after a refused credit: {tostring(why)}`)
		end
		commit(deps)
		return nil, "wallet_refused"
	end
	push(self, { kind = "sell", at = deps.now(), uid = uid, charged = 0, refunded = refund, piece = piece })
	return refund, nil
end

-- Reverses the newest action. Every refusal leaves the balance and the layout as they were. The
-- entry is popped before any wallet call so a second undo cannot reach it, and pushed back if the
-- undo is refused. Expired entries are dropped with everything older; so is one whose piece has
-- gone (no_piece), since it can never succeed. As in place and sell, the layout changes (and is
-- committed) before the wallet is called.
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
		-- Through push, so actions made while this undo was waiting on the wallet can't leave the
		-- history longer than UndoDepth.
		push(self, entry)
		return nil, why
	end

	if self.pending[entry.uid] then
		return refuse("busy")
	end

	if entry.kind == "place" then
		local piece = layout:get(entry.uid)
		if piece == nil then
			return nil, "no_piece"
		end
		layout:remove(entry.uid)
		commit(deps)
		if not wallet:credit(entry.charged, "undo place") then
			local back, why = layout:placeWithUid(piece.uid, piece.id, piece.x, piece.z, piece.r)
			if back == nil then
				error(`could not restore piece {entry.uid} after a refused credit: {tostring(why)}`)
			end
			commit(deps)
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
		commit(deps)
	else
		-- The piece goes back first, pending until the refund is charged again.
		local old = entry.piece :: Piece
		if layout:get(old.uid) ~= nil then
			return refuse("uid_taken")
		end
		local back, why = layout:placeWithUid(old.uid, old.id, old.x, old.z, old.r)
		if back == nil then
			return refuse(why)
		end
		local paid, err = chargeFor(self, old.uid, entry.refunded, "undo sell")
		if err ~= nil then
			push(self, entry)
			error(err, 0)
		elseif not paid then
			return refuse("cant_afford")
		end
	end
	return entry.kind, nil
end

function Build.snapshot(self: Build): { coins: number, pieces: { Piece } }
	return { coins = self.deps.wallet:balance(), pieces = self.deps.layout:pieces() }
end

return Build
