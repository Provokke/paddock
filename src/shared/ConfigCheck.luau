--!strict
-- Start-up sanity check for Config. Returns true, or false and a reason that names the field.
-- It never throws, whatever shape it is handed.
local ConfigCheck = {}

local function isNumber(v: any): boolean
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function isWhole(v: any, min: number): boolean
	return isNumber(v) and v >= min and v % 1 == 0
end

-- The longest piece id a client can send. Handlers drops a longer one, so it could never be placed.
local MAX_ID = 32

-- An { r, g, b } colour, each a whole number from 0 to 255.
local function isColour(v: any): boolean
	if type(v) ~= "table" or #v ~= 3 then
		return false
	end
	for i = 1, 3 do
		if not isWhole(v[i], 0) or v[i] > 255 then
			return false
		end
	end
	return true
end

local TOP_NUMBERS = {
	"SchemaVersion",
	"AutosaveSeconds",
	"LeaseSeconds",
	"LoadRetries",
	"RetryBaseSeconds",
	"CloseTimeoutSeconds",
	"CellSize",
	"StartingCoins",
	"SellRefund",
	"UndoDepth",
	"UndoSeconds",
}

function ConfigCheck.check(config: any): (boolean, string?)
	if type(config) ~= "table" then
		return false, "config must be a table"
	end
	for _, field in TOP_NUMBERS do
		if not isNumber(config[field]) then
			return false, `{field} must be a number`
		end
	end
	if type(config.DataStoreName) ~= "string" or config.DataStoreName == "" then
		return false, "DataStoreName must be a non-empty string"
	end
	if not isWhole(config.SchemaVersion, 1) then
		return false, "SchemaVersion must be a whole number of 1 or more"
	end
	if config.CellSize <= 0 then
		return false, "CellSize must be above 0"
	end
	if not isWhole(config.StartingCoins, 0) then
		return false, "StartingCoins must be a whole number of 0 or more"
	end
	if config.SellRefund < 0 or config.SellRefund > 1 then
		return false, "SellRefund must be between 0 and 1"
	end
	if not isWhole(config.UndoDepth, 0) then
		return false, "UndoDepth must be a whole number of 0 or more"
	end
	if config.UndoSeconds < 0 then
		return false, "UndoSeconds must be 0 or more"
	end
	if config.LeaseSeconds <= config.AutosaveSeconds then
		return false, "LeaseSeconds must be longer than AutosaveSeconds"
	end

	local limits = config.Limits
	if type(limits) ~= "table" then
		return false, "Limits must be a table"
	end
	for _, field in { "BurstPerPlayer", "RefillPerSecond" } do
		local v = limits[field]
		if not isNumber(v) then
			return false, `Limits.{field} must be a number`
		end
		if v <= 0 then
			return false, `Limits.{field} must be above 0`
		end
	end

	local placeables = config.Placeables
	if type(placeables) ~= "table" then
		return false, "Placeables must be a table"
	end
	for id, piece in placeables do
		if type(id) ~= "string" or #id < 1 or #id > MAX_ID then
			return false, `Placeables.{tostring(id)} needs an id of 1 to {MAX_ID} characters`
		end
		if type(piece) ~= "table" then
			return false, `Placeables.{id} must be a table`
		end
		if type(piece.name) ~= "string" or piece.name == "" then
			return false, `Placeables.{id}.name must be a non-empty string`
		end
		for _, field in { "w", "d", "maxCount" } do
			if not isWhole(piece[field], 1) then
				return false, `Placeables.{id}.{field} must be a whole number of 1 or more`
			end
		end
		if not isWhole(piece.cost, 0) then
			return false, `Placeables.{id}.cost must be a whole number of 0 or more`
		end
		if not isColour(piece.colour) then
			return false, `Placeables.{id}.colour must be three whole numbers from 0 to 255`
		end
	end

	return true, nil
end

return ConfigCheck
