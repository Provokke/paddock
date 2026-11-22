--!strict
-- Grid maths with no Roblox types, so the server, the client's mouse-to-cell code and the tests
-- all share one set of formulas. Cells are 0-based and count from the plot's min corner; the
-- plot part's CFrame is at its centre, which is what Grid.pivot measures from.
local Grid = {}

-- The footprint in cells after turning a piece r quarter turns. Odd turns swap width and depth.
function Grid.footprint(w: number, d: number, r: number): (number, number)
	if r % 2 == 1 then
		return d, w
	end
	return w, d
end

-- The plot-local centre, in studs, of a footprint whose corner cell is (x, z).
function Grid.centre(x: number, z: number, fw: number, fd: number, cellSize: number): (number, number)
	return (x + fw / 2) * cellSize, (z + fd / 2) * cellSize
end

-- Where a piece's pivot sits relative to the plot part's centre, and how far it is turned. The
-- caller applies it as plotCFrame * CFrame.new(ox, oy, oz) * CFrame.Angles(0, yaw, 0). The server
-- places the models with it and the client places the ghost with it, so they cannot drift apart.
-- w and d are the unrotated footprint in cells, sx, sy and sz are the plot part's size in studs.
function Grid.pivot(
	x: number,
	z: number,
	w: number,
	d: number,
	r: number,
	cellSize: number,
	sx: number,
	sy: number,
	sz: number
): (number, number, number, number)
	local fw, fd = Grid.footprint(w, d, r)
	local cx, cz = Grid.centre(x, z, fw, fd, cellSize)
	return -sx / 2 + cx, sy / 2, -sz / 2 + cz, r * math.pi / 2
end

-- Floors, so a point just left of or above the plot gives a negative cell rather than 0.
function Grid.cellAt(lx: number, lz: number, cellSize: number): (number, number)
	return math.floor(lx / cellSize), math.floor(lz / cellSize)
end

-- Matches CFrame.Angles(0, yaw, 0): local (1, 0, 0) lands on world (cos yaw, 0, -sin yaw).
function Grid.localToWorld(lx: number, lz: number, ox: number, oz: number, yaw: number): (number, number)
	local c, s = math.cos(yaw), math.sin(yaw)
	return ox + lx * c + lz * s, oz - lx * s + lz * c
end

function Grid.worldToLocal(wx: number, wz: number, ox: number, oz: number, yaw: number): (number, number)
	local c, s = math.cos(yaw), math.sin(yaw)
	local dx, dz = wx - ox, wz - oz
	return dx * c - dz * s, dx * s + dz * c
end

return Grid
