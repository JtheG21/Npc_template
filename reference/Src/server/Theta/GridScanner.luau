--!strict
-- GridScanner: builds a navigation grid by raycasting downward for walkable surfaces.
local GridScanner = {}

local PathTypes = require(script.Parent.PathTypes)
type Node = PathTypes.Node
type Grid = PathTypes.Grid

-- Vertical raycast band, relative to the grid center.
local RAY_ORIGIN_HEIGHT = 20
local RAY_LENGTH = 40

function GridScanner.GenerateGrid(center: Vector3, sizeX: number, sizeZ: number, nodeSpacing: number): Grid
	local grid: Grid = {}

	local startX = center.X - (sizeX * nodeSpacing) / 2
	local startZ = center.Z - (sizeZ * nodeSpacing) / 2

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	for x = 1, sizeX do
		grid[x] = {}
		for z = 1, sizeZ do
			local worldX = startX + (x - 1) * nodeSpacing
			local worldZ = startZ + (z - 1) * nodeSpacing
			local rayOrigin = Vector3.new(worldX, center.Y + RAY_ORIGIN_HEIGHT, worldZ)

			local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -RAY_LENGTH, 0), raycastParams)

			local walkable = false
			local nodePosY = center.Y

			if rayResult then
				nodePosY = rayResult.Position.Y
				if rayResult.Instance.CanCollide and not rayResult.Instance:GetAttribute("Obstacle") then
					walkable = true
				end
			end

			local newNode: Node = {
				Position = Vector3.new(worldX, nodePosY, worldZ),
				Walkable = walkable,
				G = 0,
				H = 0,
				F = 0,
				Parent = nil,
				GridX = x,
				GridZ = z,
			}
			grid[x][z] = newNode
		end
	end

	return grid
end

return GridScanner