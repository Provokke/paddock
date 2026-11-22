--!strict
local Plots = require("../../src/server/Plots")

return {
	{
		name = "players get the lowest free plot in order",
		run = function()
			local plots = Plots.new({ 1, 2, 3, 4 })
			assert(plots:claim(101) == 1)
			assert(plots:claim(102) == 2)
			assert(plots:claim(103) == 3)
		end,
	},
	{
		name = "a released plot is the next one handed out",
		run = function()
			local plots = Plots.new({ 1, 2, 3, 4 })
			plots:claim(101)
			plots:claim(102)
			plots:claim(103)
			plots:release(102)
			assert(plots:ownerOf(2) == nil and plots:plotOf(102) == nil)
			assert(plots:claim(104) == 2)
			assert(plots:claim(105) == 4)
		end,
	},
	{
		name = "claiming when every plot is taken gives nil",
		run = function()
			local plots = Plots.new({ 1, 2 })
			plots:claim(1)
			plots:claim(2)
			assert(plots:claim(3) == nil)
			assert(plots:plotOf(3) == nil)
			-- releasing a player who holds nothing changes nothing
			plots:release(3)
			assert(plots:ownerOf(1) == 1 and plots:ownerOf(2) == 2)
		end,
	},
	{
		name = "claiming twice gives the same plot and takes no second one",
		run = function()
			local plots = Plots.new({ 1, 2, 3 })
			assert(plots:claim(7) == 1)
			assert(plots:claim(7) == 1)
			assert(plots:claim(8) == 2)
		end,
	},
	{
		name = "ownerOf and plotOf agree, and unknown indices have no owner",
		run = function()
			local plots = Plots.new({ 5, 6 })
			local index = plots:claim(42)
			assert(index == 5 and plots:ownerOf(5) == 42 and plots:plotOf(42) == 5)
			assert(plots:ownerOf(6) == nil)
			assert(plots:ownerOf(99) == nil)
		end,
	},
}
