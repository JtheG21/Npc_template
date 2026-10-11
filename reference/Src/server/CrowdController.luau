--!strict
-- CrowdController: round-based zombie crowd built on the Theta* navigation grid.
local ServerScriptService = game:GetService("ServerScriptService")

local Zombie = require(script.Parent:WaitForChild("Zombie"))
local TargetService = require(script.Parent:WaitForChild("TargetService"))

local PathfindingFolder = ServerScriptService:WaitForChild("Theta")
local PathTypes = require(PathfindingFolder:WaitForChild("PathTypes"))
local GridScanner = require(PathfindingFolder:WaitForChild("GridScanner"))
local ThetaSolver = require(PathfindingFolder:WaitForChild("ThetaSolver"))
local GridVisualizer = require(PathfindingFolder:WaitForChild("GridVisualizer"))

type Node = PathTypes.Node
type Grid = PathTypes.Grid
type Zombie = Zombie.Zombie

-- --- GRID PARAMETERS ---
local NODE_SPACING = 4
local MAP_CENTER = Vector3.zero
local GRID_SIZE_X = 60
local GRID_SIZE_Z = 60

-- --- SIMULATION PARAMETERS ---
local STEER_INTERVAL = 0.15 -- Steering ticks, roughly 6 per second
local ATTACK_MODE_DELAY = 2 -- Seconds zombies idle with green eyes before attack mode activates
local SPAWN_SEARCH_RADIUS = 4 -- Grid rings searched for a walkable node around each spawn point
local SPAWN_HEIGHT_OFFSET = Vector3.new(0, 3, 0) -- Lifts the root part above the floor node
local NPC_FOLDER_NAME = "CROWD_NPCS"

type CrowdFields = {
	-- Round tuning dials.
	Tightness: number, -- How tightly each batch spawns together (higher = narrower gate)
	Spread: number, -- Distance from the target that batches spawn at, in studs
	Speed: number,
	Health: number,
	RoundDelay: number,
	StartCount: number,
	GrowthFactor: number, -- Batch size multiplier per wave: 2 -> 4 -> 8 -> 16 ...
	MaxZombies: number,
	Names: { string },

	ActiveZombies: { Zombie },
	Running: boolean,
	OnStopped: (() -> ())?, -- Fired when the crowd winds down on its own (all prey dead)

	-- Route cache: re-solve only when an endpoint moves to a different grid
	-- node, instead of on every steering tick.
	CachedStartNode: Node?,
	CachedEndNode: Node?,
	CachedPath: { Vector3 }?,

	GameGrid: Grid,
	NpcFolder: Folder,
}

local CrowdController = {}
CrowdController.__index = CrowdController

export type CrowdController = typeof(setmetatable({} :: CrowdFields, CrowdController))

local singleton: CrowdController? = nil

-- Every zombie lives in one folder so pathfinding can exclude the whole crowd
-- from line-of-sight rays in a single filter entry.
local function getNpcFolder(): Folder
	local existing = workspace:FindFirstChild(NPC_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = NPC_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

function CrowdController.new(): CrowdController
	if singleton then return singleton end

	-- Build the navigation grid once, then draw the debug snapshot.
	print("Scanning environment for the crowd navigation grid...")
	local grid = GridScanner.GenerateGrid(MAP_CENTER, GRID_SIZE_X, GRID_SIZE_Z, NODE_SPACING)
	print("Grid scan complete.")
	GridVisualizer.DrawGrid(grid, GRID_SIZE_X, GRID_SIZE_Z)

	local fields: CrowdFields = {
		Tightness = 6,
		Spread = 40,
		Speed = 23,
		Health = 50,
		RoundDelay = 8,
		StartCount = 2,
		GrowthFactor = 2,
		MaxZombies = 60,
		Names = { "Shambler", "Walker", "Lurker", "Crawler" },

		ActiveZombies = {},
		Running = false,
		OnStopped = nil,

		CachedStartNode = nil,
		CachedEndNode = nil,
		CachedPath = nil,

		GameGrid = grid,
		NpcFolder = getNpcFolder(),
	}

	local self = setmetatable(fields, CrowdController)
	singleton = self
	return self
end

-- Maps a world position onto the nearest grid node.
function CrowdController.GetClosestNode(self: CrowdController, worldPos: Vector3): Node?
	local startX = MAP_CENTER.X - (GRID_SIZE_X * NODE_SPACING) / 2
	local startZ = MAP_CENTER.Z - (GRID_SIZE_Z * NODE_SPACING) / 2

	local xIdx = math.clamp(math.round((worldPos.X - startX) / NODE_SPACING) + 1, 1, GRID_SIZE_X)
	local zIdx = math.clamp(math.round((worldPos.Z - startZ) / NODE_SPACING) + 1, 1, GRID_SIZE_Z)

	local column = self.GameGrid[xIdx]
	return column and column[zIdx]
end

-- Snaps a desired spawn point to the nearest walkable grid node, searching
-- outward in square rings so zombies never spawn inside walls or off the map.
function CrowdController.FindSpawnNode(self: CrowdController, worldPos: Vector3): Node?
	local origin = self:GetClosestNode(worldPos)
	if not origin then return nil end

	for radius = 0, SPAWN_SEARCH_RADIUS do
		for dx = -radius, radius do
			for dz = -radius, radius do
				-- Only visit the ring's border; smaller radii already covered the inside.
				if math.max(math.abs(dx), math.abs(dz)) ~= radius then continue end

				local column = self.GameGrid[origin.GridX + dx]
				local node = column and column[origin.GridZ + dz]
				if node and node.Walkable then
					return node
				end
			end
		end
	end
	return nil
end

-- Drops dead or frozen records so counts and the lead zombie only see the living.
function CrowdController.PruneDead(self: CrowdController)
	for i = #self.ActiveZombies, 1, -1 do
		local zombie = self.ActiveZombies[i]
		if table.isfrozen(zombie) or not zombie.Model.Parent then
			table.remove(self.ActiveZombies, i)
		end
	end
end

-- Resolves the single player the whole crowd hunts: the living player closest
-- to the lead zombie, or any living player before a lead exists. Spawning,
-- routing, and every zombie's Update all use this one answer.
local function resolveTarget(leadZombie: Zombie?): (Humanoid?, BasePart?)
	local origin = if leadZombie then leadZombie.RootPart else nil
	local player = TargetService.getNearestPlayer(origin)
	local character = player and player.Character
	if not character then return nil, nil end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return nil, nil
	end
	return humanoid, root
end

-- Spawns positions spread across a random "gate" arc around the center,
-- alternating inner and outer radii so batches have room to breathe.
local function getSpawnPositions(center: Vector3, count: number, tightness: number, spread: number): { Vector3 }
	local gate = math.random() * math.pi * 2
	local arc = math.pi / tightness
	local positions = {}

	for i = 1, count do
		local t = (i - 1) / math.max(count - 1, 1)
		local angle = gate + (t * 2 - 1) * arc

		local radius = spread
		if i % 2 == 0 then
			radius += 6
		end

		table.insert(positions, center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
	end
	return positions
end

-- Spawns a batch of zombies around the current target. Returns how many spawned.
function CrowdController.SpawnBatch(self: CrowdController, count: number): number
	self:PruneDead()

	local _, targetRoot = resolveTarget(self.ActiveZombies[1])
	local center = if targetRoot then targetRoot.Position else MAP_CENTER
	local spawned = 0

	for _, position in getSpawnPositions(center, count, self.Tightness, self.Spread) do
		if #self.ActiveZombies >= self.MaxZombies then break end

		-- Skip spawn points with no walkable floor nearby rather than dropping
		-- a zombie into a wall or off the map.
		local spawnNode = self:FindSpawnNode(position)
		if not spawnNode then continue end

		local zombie = Zombie.new(self.Names[math.random(#self.Names)], self.Health, self.NpcFolder, self.Speed)
		zombie.Model:PivotTo(CFrame.new(spawnNode.Position + SPAWN_HEIGHT_OFFSET))
		table.insert(self.ActiveZombies, zombie)
		spawned += 1

		-- Fresh spawns idle with green eyes briefly, then attack mode kicks in.
		task.delay(ATTACK_MODE_DELAY, function()
			if self.Running and not table.isfrozen(zombie) and zombie.State == "Idle" then
				zombie:EnterAttackMode()
			end
		end)
	end
	return spawned
end

-- Stops the simulation: every zombie exits attack mode, idles with green
-- eyes, and cleans itself up. Fires OnStopped so the host button resets.
function CrowdController.Stop(self: CrowdController)
	if not self.Running then return end
	self.Running = false

	-- Drop the route cache so the next round starts from a clean slate.
	self.CachedStartNode = nil
	self.CachedEndNode = nil
	self.CachedPath = nil

	for _, zombie in self.ActiveZombies do
		if not table.isfrozen(zombie) then
			zombie:ExitAttackMode()
		end
	end
	table.clear(self.ActiveZombies)

	local onStopped = self.OnStopped
	if onStopped then
		task.spawn(onStopped)
	end
end

-- Solves (or reuses) the shared route from the lead zombie to the target.
-- Returns nil when the grid can't connect them, so the crowd pursues directly.
function CrowdController.GetSharedPath(self: CrowdController, fromPosition: Vector3, targetPosition: Vector3): { Vector3 }?
	local startNode = self:GetClosestNode(fromPosition)
	local endNode = self:GetClosestNode(targetPosition)

	if not (startNode and endNode and startNode.Walkable and endNode.Walkable and startNode ~= endNode) then
		-- Endpoints unusable: drop the cache so no stale route lingers.
		self.CachedStartNode = nil
		self.CachedEndNode = nil
		self.CachedPath = nil
		return nil
	end

	-- Route cache: re-solve only when an endpoint lands on a new grid node.
	-- Re-solving every tick let equal-cost routes alternate between solves,
	-- which read as zigzagging and aim-point flips.
	if startNode == self.CachedStartNode and endNode == self.CachedEndNode and self.CachedPath then
		return self.CachedPath
	end

	local path = ThetaSolver.FindPath(self.GameGrid, startNode, endNode, GRID_SIZE_X, GRID_SIZE_Z, { self.NpcFolder })
	self.CachedStartNode = startNode
	self.CachedEndNode = endNode
	self.CachedPath = path

	-- Render only freshly solved routes; cached ones are already on screen.
	if path then
		GridVisualizer.DrawPath(path)
	end
	return path
end

-- Starts the round loop and the central steering tick.
function CrowdController.Start(self: CrowdController)
	if self.Running then return end
	self.Running = true

	-- Round thread: each wave multiplies the batch size, capped at the crowd limit.
	task.spawn(function()
		local count = self.StartCount
		while self.Running do
			self:SpawnBatch(count)
			count = math.min(count * self.GrowthFactor, self.MaxZombies)
			task.wait(self.RoundDelay)
		end
	end)

	-- Steering thread: picks one target and one shared route per tick and
	-- feeds both to every zombie in the crowd.
	task.spawn(function()
		while self.Running do
			task.wait(STEER_INTERVAL)

			-- No living prey anywhere (death or disconnect): stop the round.
			-- Stop winds every zombie down to idle and resets the button.
			if not TargetService.getNearestPlayer(nil) then
				self:Stop()
				continue
			end

			self:PruneDead()
			local leadZombie = self.ActiveZombies[1]
			if not leadZombie then continue end

			local targetHumanoid, targetRoot = resolveTarget(leadZombie)
			if not targetHumanoid or not targetRoot then continue end

			local sharedPath = self:GetSharedPath(leadZombie.RootPart.Position, targetRoot.Position)

			for _, zombie in self.ActiveZombies do
				if table.isfrozen(zombie) then continue end

				-- Clean up zombies whose health hit zero between ticks.
				if zombie.Humanoid.Health <= 0 then
					task.spawn(zombie.Die, zombie)
					continue
				end

				zombie:Update(sharedPath, targetHumanoid, targetRoot)
			end
		end
	end)
end

return CrowdController
