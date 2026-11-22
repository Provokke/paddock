--!strict
-- The shape of one player's saved data: what a brand new profile holds, and how the session form
-- is turned into the stored form and back.
--
--   coins   number               the player's wallet
--   layout  { { id, x, z, r } }  the pieces placed on their paddock
--
-- Coins and layout live in one record, so every save writes both together. encode and decode
-- copy every field, so a field added to defaultData is saved and loaded without anyone having
-- to remember to list it here.
local Profile = {}

type Data = { [string]: any }

export type Deps = {
	startingCoins: number, -- what a new player starts with
}

export type Profile = {
	defaultData: () -> Data,
	encode: (data: Data) -> Data,
	decode: (saved: Data) -> Data,
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[deepCopy(k)] = deepCopy(v)
	end
	return out
end

function Profile.new(deps: Deps): Profile
	-- The starting coins are part of the default data, so the claim that creates the record
	-- writes them. A player who leaves (or a server that crashes) before the first save still
	-- has them next time, and they are never granted twice.
	local function defaultData(): Data
		return { coins = deps.startingCoins, layout = {} }
	end

	-- Session form to stored form. Runs inside UpdateAsync transforms, so it must not yield.
	local function encode(data: Data): Data
		return deepCopy(data)
	end

	-- Stored form to session form. Data that isn't a table, or that has no coin balance, is
	-- refused, so the load fails and the record is left alone instead of being opened as an
	-- empty profile (which would hand out the starting coins again).
	local function decode(saved: Data): Data
		if type(saved) ~= "table" then
			error("saved data is not a table")
		end
		if type(saved.coins) ~= "number" then
			error("saved data has no coins")
		end
		local out = deepCopy(saved)
		if type(out.layout) ~= "table" then
			out.layout = {}
		end
		return out
	end

	return { defaultData = defaultData, encode = encode, decode = decode }
end

return Profile
