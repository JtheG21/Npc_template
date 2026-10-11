--!strict
-- GridVisualizer: debug rendering for the navigation grid and active paths.
local PathTypes = require(script.Parent.PathTypes)
type Grid = PathTypes.Grid

local GridVisualizer = {}

local CONTAINER_NAME = "THETA_GRID_DEBUG"

-- Removes the previous snapshot so a fresh one can be drawn.
local function clearOldGrid()
	local existing = workspace:FindFirstChild(CONTAINER_NAME)
	if existing then
		existing:Destroy()
	end
end

-- Draws one ball per grid node: green = walkable, red = blocked.
function GridVisualizer.DrawGrid(grid: Grid, sizeX: number, sizeZ: number)
	clearOldGrid()

	local folder = Instance.new("Folder")
	folder.Name = CONTAINER_NAME
	folder.Parent = workspace

	-- Clone a single configured archetype instead of setting up every part from scratch.
	local partTemplate = Instance.new("Part")
	partTemplate.Shape = Enum.PartType.Ball
	partTemplate.Size = Vector3.new(1, 1, 1)
	partTemplate.Anchored = true
	partTemplate.CanCollide = false
	partTemplate.CanQuery = false -- Debug parts must never block pathfinding raycasts
	partTemplate.CanTouch = false
	partTemplate.CastShadow = false
	partTemplate.Material = Enum.Material.Neon

	for x = 1, sizeX do
		for z = 1, sizeZ do
			local node = grid[x][z]
			if not node then continue end

			local visualPart = partTemplate:Clone()
			visualPart.Position = node.Position

			if node.Walkable then
				visualPart.Color = Color3.fromRGB(0, 255, 100)
				visualPart.Transparency = 0.85 -- Fade walkable nodes so they stay unobtrusive
			else
				visualPart.Color = Color3.fromRGB(255, 50, 50)
				visualPart.Transparency = 0.4 -- Make blocked nodes stand out
			end

			visualPart.Parent = folder
		end
	end
end

-- Draws the active path as neon segments between waypoints.
function GridVisualizer.DrawPath(waypoints: { Vector3 })
	local folder = workspace:FindFirstChild(CONTAINER_NAME)
	if not folder then return end

	local oldPath = folder:FindFirstChild("ActivePathLines")
	if oldPath then
		oldPath:Destroy()
	end

	local pathFolder = Instance.new("Folder")
	pathFolder.Name = "ActivePathLines"
	pathFolder.Parent = folder

	if #waypoints < 2 then return end

	for i = 1, #waypoints - 1 do
		local pointA = waypoints[i]
		local pointB = waypoints[i + 1]

		local line = Instance.new("Part")
		line.Size = Vector3.new(0.4, 0.4, (pointA - pointB).Magnitude)
		line.CFrame = CFrame.lookAt(pointA:Lerp(pointB, 0.5), pointB)
		line.Anchored = true
		line.CanCollide = false
		line.CanQuery = false -- Debug parts must never block pathfinding raycasts
		line.CanTouch = false
		line.CastShadow = false
		line.Color = Color3.fromRGB(0, 180, 255)
		line.Material = Enum.Material.Neon
		line.Parent = pathFolder
	end
end

return GridVisualizer
