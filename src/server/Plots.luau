--!strict
-- Which player owns which plot. A pure table: the entry script decides what a plot index means.
local Plots = {}
Plots.__index = Plots

export type Plots = typeof(setmetatable(
	{} :: {
		indices: { number }, -- every plot, in the order they are handed out
		owners: { [number]: number }, -- plot index -> UserId
		plotByUser: { [number]: number }, -- UserId -> plot index
	},
	Plots
))

function Plots.new(indices: { number }): Plots
	local ordered = table.clone(indices)
	table.sort(ordered)
	return setmetatable({ indices = ordered, owners = {}, plotByUser = {} }, Plots)
end

-- The lowest free plot for this player, or nil when all are taken. Claiming again returns the
-- plot they already hold.
function Plots.claim(self: Plots, userId: number): number?
	local held = self.plotByUser[userId]
	if held ~= nil then
		return held
	end
	for _, index in self.indices do
		if self.owners[index] == nil then
			self.owners[index] = userId
			self.plotByUser[userId] = index
			return index
		end
	end
	return nil
end

function Plots.release(self: Plots, userId: number)
	local held = self.plotByUser[userId]
	if held == nil then
		return
	end
	self.plotByUser[userId] = nil
	self.owners[held] = nil
end

function Plots.ownerOf(self: Plots, index: number): number?
	return self.owners[index]
end

function Plots.plotOf(self: Plots, userId: number): number?
	return self.plotByUser[userId]
end

return Plots
