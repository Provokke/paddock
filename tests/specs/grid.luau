--!strict
local Grid = require("../../src/shared/Grid")

local EPS = 1e-9

local function near(a: number, b: number, what: string)
	assert(math.abs(a - b) <= EPS, `{what}: expected {b}, got {a}`)
end

return {
	{
		name = "footprint swaps width and depth on odd rotations",
		run = function()
			local expected = { { 3, 2 }, { 2, 3 }, { 3, 2 }, { 2, 3 } }
			for r = 0, 3 do
				local w, d = Grid.footprint(3, 2, r)
				assert(w == expected[r + 1][1] and d == expected[r + 1][2], `r = {r}: got {w}, {d}`)
			end
		end,
	},
	{
		name = "centre is the middle of the footprint in plot-local studs",
		run = function()
			local x, z = Grid.centre(0, 0, 1, 1, 4)
			assert(x == 2 and z == 2, `got {x}, {z}`)
			local x2, z2 = Grid.centre(2, 1, 3, 2, 4)
			assert(x2 == 14 and z2 == 8, `got {x2}, {z2}`)
		end,
	},
	{
		name = "cellAt floors a local point to its cell",
		run = function()
			local x, z = Grid.cellAt(15.9, 4, 4)
			assert(x == 3 and z == 1, `got {x}, {z}`)
			local x2, z2 = Grid.cellAt(0, 0, 4)
			assert(x2 == 0 and z2 == 0, `got {x2}, {z2}`)
		end,
	},
	{
		name = "cellAt of a cell's centre gives the cell back",
		run = function()
			for x = 0, 9 do
				for z = 0, 7 do
					local cx, cz = Grid.centre(x, z, 1, 1, 4)
					local rx, rz = Grid.cellAt(cx, cz, 4)
					assert(rx == x and rz == z, `cell {x},{z} came back as {rx},{rz}`)
				end
			end
		end,
	},
	{
		name = "a yaw of 0 only shifts by the plot origin",
		run = function()
			local lx, lz = Grid.worldToLocal(102, 52, 100, 50, 0)
			near(lx, 2, "lx")
			near(lz, 2, "lz")
		end,
	},
	{
		name = "yaw follows the CFrame.Angles(0, yaw, 0) convention",
		run = function()
			local wx, wz = Grid.localToWorld(1, 0, 100, 50, math.pi / 2)
			near(wx, 100, "wx")
			near(wz, 49, "wz")
		end,
	},
	{
		name = "worldToLocal undoes localToWorld",
		run = function()
			local yaws = { 0, math.pi / 2, math.pi, 3 * math.pi / 2, 0.3 }
			for _, yaw in yaws do
				for i = 1, 20 do
					local lx, lz = i * 1.7 - 5, 31 - i * 2.3
					local wx, wz = Grid.localToWorld(lx, lz, 100, 50, yaw)
					local bx, bz = Grid.worldToLocal(wx, wz, 100, 50, yaw)
					near(bx, lx, `yaw {yaw} lx`)
					near(bz, lz, `yaw {yaw} lz`)
				end
			end
		end,
	},
}
