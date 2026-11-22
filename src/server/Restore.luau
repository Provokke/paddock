--!strict
-- Rebuilds a paddock from the saved layout. Each entry goes through the Layout's own rules, so a
-- saved layout can never place anything a live player couldn't. What doesn't fit is dropped, and
-- a real piece that was dropped is refunded part of its cost. Nothing is credited here: the
-- caller adds `refund` to the wallet once.
local Restore = {}

export type Dropped = { entry: any, reason: string }
export type Result = { kept: number, refund: number, dropped: { Dropped } }

-- A whole, finite number. Fails for NaN, infinity, fractions and non-numbers.
local function whole(value: any): boolean
	return type(value) == "number" and value == math.floor(value) and math.abs(value) < math.huge
end

function Restore.run(
	entries: any,
	layout: any,
	defs: { [string]: { cost: number } },
	sellRefund: number
): Result
	local result: Result = { kept = 0, refund = 0, dropped = {} }
	if type(entries) ~= "table" then
		return result
	end
	for _, entry in entries do
		local sound = type(entry) == "table"
			and type(entry.id) == "string"
			and whole(entry.x)
			and whole(entry.z)
			and whole(entry.r)
		if not sound then
			table.insert(result.dropped, { entry = entry, reason = "malformed" })
			continue
		end
		local def = defs[entry.id]
		if def == nil then
			table.insert(result.dropped, { entry = entry, reason = "unknown_item" })
			continue
		end
		local piece, why = layout:place(entry.id, entry.x, entry.z, entry.r)
		if piece ~= nil then
			result.kept += 1
		else
			result.refund += math.floor(def.cost * sellRefund)
			table.insert(result.dropped, { entry = entry, reason = why or "refused" })
		end
	end
	return result
end

return Restore
