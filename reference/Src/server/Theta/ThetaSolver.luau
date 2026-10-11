--!strict
-- ThetaSolver: any-angle pathfinding (Theta*). Falls back to standard A* edges
-- when line of sight between nodes is blocked.
local Players = game:GetService("Players")

local PathTypes = require(script.Parent.PathTypes)
type Node = PathTypes.Node
type Grid = PathTypes.Grid

local ThetaSolver = {}

-- Clearance above the floor for line-of-sight rays, so they don't graze walkable surfaces.
local LINE_OF_SIGHT_CLEARANCE = 2
-- Grid samples taken per node step when walking a shortcut's footprint.
local FLOOR_SAMPLES_PER_NODE = 2
-- Largest height change between neighboring floor samples a body can step or hop.
local MAX_FLOOR_STEP = 3.5

-- Heuristic with a tiny tie-breaker: among equal-cost routes the solver
-- consistently prefers the same one, instead of alternating between them on
-- consecutive solves (the source of visible route flipping).
local HEURISTIC_TIE_BREAK = 0.001

local function getDistance(nodeA: Node, nodeB: Node): number
	return (nodeA.Position - nodeB.Position).Magnitude
end

local function getHeuristic(node: Node, endNode: Node): number
	return getDistance(node, endNode) * (1 + HEURISTIC_TIE_BREAK)
end

-- Floor check: walks the grid cells beneath a shortcut so it never crosses a
-- hole, blocked cell, or cliff that an eye-level ray would pass straight over.
local function hasContinuousFloor(grid: Grid, nodeA: Node, nodeB: Node): boolean
	local deltaX = nodeB.GridX - nodeA.GridX
	local deltaZ = nodeB.GridZ - nodeA.GridZ
	local steps = math.max(math.abs(deltaX), math.abs(deltaZ)) * FLOOR_SAMPLES_PER_NODE
	if steps == 0 then return true end

	local previousY = nodeA.Position.Y
	for step = 1, steps do
		local t = step / steps
		local column = grid[math.round(nodeA.GridX + deltaX * t)]
		local cell = column and column[math.round(nodeA.GridZ + deltaZ * t)]
		if not cell or not cell.Walkable then return false end
		if math.abs(cell.Position.Y - previousY) > MAX_FLOOR_STEP then return false end
		previousY = cell.Position.Y
	end
	return true
end

-- Line-of-sight check used to skip staircased grid edges and produce smooth paths.
-- The cheap grid floor walk runs first; the raycast only confirms nothing solid
-- stands in the way at body height.
local function hasLineOfSight(grid: Grid, nodeA: Node, nodeB: Node, raycastParams: RaycastParams): boolean
	if not hasContinuousFloor(grid, nodeA, nodeB) then return false end

	local origin = nodeA.Position + Vector3.new(0, LINE_OF_SIGHT_CLEARANCE, 0)
	local target = nodeB.Position + Vector3.new(0, LINE_OF_SIGHT_CLEARANCE, 0)

	local result = workspace:Raycast(origin, target - origin, raycastParams)
	return result == nil -- A clear ray means the segment is walkable
end

-- Clears G costs and parent pointers left over from previous searches. The grid
-- nodes are shared and mutated in place, so without this a stale Parent chain
-- from an earlier solve could corrupt (or cycle) the next backtracking walk.
local function resetSearchState(grid: Grid, sizeX: number, sizeZ: number)
	for x = 1, sizeX do
		local column = grid[x]
		if not column then continue end
		for z = 1, sizeZ do
			local node = column[z]
			if node then
				node.G = 0
				node.Parent = nil
			end
		end
	end
end

-- Builds the raycast filter once per solve: skips the debug visualization,
-- every player character, and any caller-supplied instances (such as the NPC
-- folder) so moving bodies never fake-block a sightline.
local function buildRaycastParams(extraExclusions: { Instance }?): RaycastParams
	local exclusions: { Instance } = {}

	local debugFolder = workspace:FindFirstChild("THETA_GRID_DEBUG")
	if debugFolder then
		table.insert(exclusions, debugFolder)
	end

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclusions, player.Character)
		end
	end

	if extraExclusions then
		for _, instance in extraExclusions do
			table.insert(exclusions, instance)
		end
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = exclusions
	return raycastParams
end

local function getNeighbors(grid: Grid, node: Node, sizeX: number, sizeZ: number): { Node }
	local neighbors = {}
	for x = -1, 1 do
		for z = -1, 1 do
			if x == 0 and z == 0 then continue end

			local newX = node.GridX + x
			local newZ = node.GridZ + z
			if newX < 1 or newX > sizeX or newZ < 1 or newZ > sizeZ then continue end

			local targetNode = grid[newX][newZ]
			if not targetNode or not targetNode.Walkable then continue end

			-- Corner-cutting guard: a diagonal step is only legal when both
			-- flanking orthogonal neighbors are walkable, so bodies never
			-- clip through blocked corners.
			if x ~= 0 and z ~= 0 then
				local flankA = grid[newX][node.GridZ]
				local flankB = grid[node.GridX][newZ]
				if not flankA or not flankA.Walkable or not flankB or not flankB.Walkable then
					continue
				end
			end

			table.insert(neighbors, targetNode)
		end
	end
	return neighbors
end

-- Final smoothing pass: drops waypoints that sit (almost) on the straight
-- line between their kept neighbors — leftover micro-bends from the parent
-- chain that would otherwise surface as visible zigzag while steering.
local COLLINEARITY_EPSILON = 0.05 -- Studs of lateral deviation tolerated

local function trimRedundantBends(path: { Vector3 }): { Vector3 }
	if #path < 3 then return path end

	local trimmed: { Vector3 } = { path[1] }
	for i = 2, #path - 1 do
		local anchor = trimmed[#trimmed]
		local current = path[i]
		local nextPoint = path[i + 1]

		-- Perpendicular deviation of `current` from the anchor->next segment.
		local segment = nextPoint - anchor
		local deviation = segment:Cross(current - anchor).Magnitude / math.max(segment.Magnitude, 1e-6)

		if deviation > COLLINEARITY_EPSILON then
			table.insert(trimmed, current)
		end
	end
	table.insert(trimmed, path[#path])
	return trimmed
end

-- Finds a path from startNode to endNode, or nil if no route exists.
-- `ignoreList` holds extra instances that must never block sightlines.
function ThetaSolver.FindPath(
	grid: Grid,
	startNode: Node,
	endNode: Node,
	sizeX: number,
	sizeZ: number,
	ignoreList: { Instance }?
): { Vector3 }?
	resetSearchState(grid, sizeX, sizeZ)
	local raycastParams = buildRaycastParams(ignoreList)

	local openSet = PathTypes.newMinHeap()
	local closedSet: { [Node]: boolean } = {}

	startNode.G = 0
	startNode.H = getHeuristic(startNode, endNode)
	startNode.F = startNode.G + startNode.H
	startNode.Parent = startNode -- Sentinel so backtracking terminates at the start

	openSet:Insert(startNode)

	while not openSet:IsEmpty() do
		local current = openSet:Pop()
		if not current then break end
		if closedSet[current] then continue end -- Stale duplicate heap entry

		if current == endNode then
			-- Backtrack from the goal to the start, building the waypoint list.
			local path: { Vector3 } = {}
			local curr: Node? = endNode
			while curr and curr ~= startNode do
				table.insert(path, 1, curr.Position)
				curr = curr.Parent
			end
			return trimRedundantBends(path)
		end

		closedSet[current] = true

		for _, neighbor in getNeighbors(grid, current, sizeX, sizeZ) do
			if closedSet[neighbor] then continue end

			-- Theta* shortcut: connect straight to the current node's parent when
			-- the segment is visible; otherwise fall back to the standard A* edge.
			local parentNode = current.Parent or current
			local viaNode = if hasLineOfSight(grid, parentNode, neighbor, raycastParams) then parentNode else current

			local newG = viaNode.G + getDistance(viaNode, neighbor)
			if neighbor.G == 0 or newG < neighbor.G then
				neighbor.G = newG
				neighbor.H = getHeuristic(neighbor, endNode)
				neighbor.F = neighbor.G + neighbor.H
				neighbor.Parent = viaNode
				openSet:Insert(neighbor)
			end
		end
	end

	return nil -- No path found
end

return ThetaSolver