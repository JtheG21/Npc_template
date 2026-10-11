--!strict
-- Zombie: a crowd NPC. Owns its model, eye states, melee attacks, and path steering.
local ServerStorage = game:GetService("ServerStorage")

local Zombie = {}
Zombie.__index = Zombie

local TEMPLATE = ServerStorage:WaitForChild("Guy") :: Model

local DEFAULT_SPEED = 25
local ATTACK_DAMAGE = 15
local ATTACK_COOLDOWN = 1
local ATTACK_RANGE = 5 -- Max distance for melee swipes
local WAYPOINT_REACH_RADIUS = 6 -- Distance at which a route waypoint counts as reached
local FINAL_APPROACH_RADIUS = 25 -- Distance from the route's end at which zombies stop steering and close in
local JUMP_HEIGHT_THRESHOLD = 3.5 -- Height mismatch that triggers a hop
local CLEANUP_DELAY = 2 -- Seconds a zombie idles with green eyes before cleaning up

local HOSTILE_IRIS_COLOR = BrickColor.new("Maroon")
local HOSTILE_EYE_COLOR = BrickColor.new("Really red")

export type ZombieState = "Idle" | "Hunting" | "WindingDown"

-- A single recolorable eye part, with its idle color kept for restoration.
type EyeRecord = {
	Part: BasePart,
	IdleColor: BrickColor,
	IsIris: boolean,
}

type ZombieFields = {
	Model: Model,
	RootPart: BasePart,
	Humanoid: Humanoid,
	EyeRecords: { EyeRecord },
	State: ZombieState,
	Name: string,
	BaseHealth: number,
	Speed: number,
	IsOnAttackCooldown: boolean,
	CurrentTarget: Humanoid?,
	CurrentPath: { Vector3 }?, -- Route table currently followed (compared by identity)
	WaypointIndex: number, -- Forward-only progress along the current route
}

export type Zombie = typeof(setmetatable({} :: ZombieFields, Zombie))

-- Snapshots every BasePart inside an eyeball (iris, pupil, sclera) so the
-- whole eye recolors — no part gets left behind — and restores exactly.
local function collectEyeParts(eyeBall: Instance?, into: { EyeRecord })
	if not eyeBall then return end

	local irisModel = eyeBall:FindFirstChild("iris")
	for _, descendant in eyeBall:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(into, {
				Part = descendant,
				IdleColor = descendant.BrickColor,
				IsIris = irisModel ~= nil and descendant:IsDescendantOf(irisModel),
			})
		end
	end
end

function Zombie.new(name: string, health: number, parent: Instance?, speed: number?): Zombie
	local model = TEMPLATE:Clone()

	-- Snapshot both eyes so idle and hostile looks swap losslessly.
	local eyeRecords: { EyeRecord } = {}
	collectEyeParts(model:FindFirstChild("Left eye ball"), eyeRecords)
	collectEyeParts(model:FindFirstChild("Right eye ball"), eyeRecords)

	local humanoid = model:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = health
	humanoid.Health = health
	humanoid.WalkSpeed = 0 -- Idle until attack mode activates

	model.Name = name
	model.Parent = parent or workspace

	-- Zombies spawn idle (green eyes, standing still); the crowd controller
	-- activates attack mode on its own schedule.
	local fields: ZombieFields = {
		Model = model,
		RootPart = model:WaitForChild("HumanoidRootPart") :: BasePart,
		Humanoid = humanoid,
		EyeRecords = eyeRecords,
		State = "Idle",
		Name = name,
		BaseHealth = health,
		Speed = speed or DEFAULT_SPEED,
		IsOnAttackCooldown = false,
		CurrentTarget = nil,
		CurrentPath = nil,
		WaypointIndex = 1,
	}
	return setmetatable(fields, Zombie)
end

-- Hostile look: irises turn maroon, every other eye part (pupil, sclera) red.
function Zombie.EyesTurnRed(self: Zombie)
	for _, record in self.EyeRecords do
		record.Part.BrickColor = if record.IsIris then HOSTILE_IRIS_COLOR else HOSTILE_EYE_COLOR
	end
end

-- Idle look: restores the exact eye colors captured at spawn.
function Zombie.EyesTurnGreen(self: Zombie)
	for _, record in self.EyeRecords do
		record.Part.BrickColor = record.IdleColor
	end
end

-- Attack mode: red eyes, hunting speed, periodic growls.
function Zombie.EnterAttackMode(self: Zombie)
	if table.isfrozen(self) or self.State ~= "Idle" then return end
	self.State = "Hunting"
	self:EyesTurnRed()
	self.Humanoid.WalkSpeed = self.Speed

	task.spawn(function()
		while not table.isfrozen(self) and self.Model.Parent and self.State == "Hunting" do
			task.wait(math.random(2, 5))
			-- Re-check after the wait: the zombie may have wound down mid-interval.
			if table.isfrozen(self) or self.State ~= "Hunting" then break end
			self:PlaySound()
		end
	end)
end

-- Wind-down: back to idle (green eyes, standing still), then clean up.
function Zombie.ExitAttackMode(self: Zombie)
	if table.isfrozen(self) or self.State == "WindingDown" then return end
	self.State = "WindingDown"
	self.Humanoid.WalkSpeed = 0
	self:EyesTurnGreen()

	task.delay(CLEANUP_DELAY, function()
		if not table.isfrozen(self) then
			self:Die()
		end
	end)
end

-- Destroys the model (not just unparenting it) so the clone's connections and
-- memory are released, then freezes the record so stale references no-op.
function Zombie.Die(self: Zombie)
	if table.isfrozen(self) then return end
	self.Model:Destroy()
	table.clear(self)
	table.freeze(self)
end

-- Melee swipe, triggered whenever a living target is within attack range.
function Zombie.Attack(self: Zombie, targetHumanoid: Humanoid)
	if self.IsOnAttackCooldown then return end

	self.IsOnAttackCooldown = true
	targetHumanoid:TakeDamage(ATTACK_DAMAGE)

	task.delay(ATTACK_COOLDOWN, function()
		if not table.isfrozen(self) then
			self.IsOnAttackCooldown = false
		end
	end)
end

-- Per-tick update. The crowd controller picks one target for the whole crowd
-- and passes it in, so every zombie chases the same player the shared route
-- was solved for. Swipes when in melee range, otherwise steers along the
-- route — or straight at the target when no route exists.
function Zombie.Update(self: Zombie, waypoints: { Vector3 }?, targetHumanoid: Humanoid?, targetRoot: BasePart?)
	if table.isfrozen(self) or self.State ~= "Hunting" then return end
	if self.Humanoid.Health <= 0 then return end
	self.Humanoid.WalkSpeed = self.Speed

	-- Nothing living to hunt right now: stand by until the crowd winds down.
	if not targetHumanoid or targetHumanoid.Health <= 0 or not targetRoot then
		return
	end
	self.CurrentTarget = targetHumanoid
	local targetPosition = targetRoot.Position

	-- In melee range: press into the target and swipe on cooldown.
	if (self.RootPart.Position - targetPosition).Magnitude <= ATTACK_RANGE then
		self:Attack(targetHumanoid)
		self.Humanoid:MoveTo(targetPosition)
		return
	end

	-- No usable route: pursue the target directly.
	if not waypoints or #waypoints == 0 then
		self.Humanoid:MoveTo(targetPosition)
		return
	end

	-- Close to the route's end: head straight for the final waypoint.
	local finalTarget = waypoints[#waypoints]
	if (self.RootPart.Position - finalTarget).Magnitude < FINAL_APPROACH_RADIUS then
		self.Humanoid:MoveTo(finalTarget)
		return
	end

	-- New route from the controller: restart progress from the front. The
	-- route table's identity is stable between ticks (the controller caches
	-- it), so progress only resets when a genuinely new route arrives.
	if waypoints ~= self.CurrentPath then
		self.CurrentPath = waypoints
		self.WaypointIndex = 1
	end

	-- Advance past waypoints already reached — forward only, never backwards,
	-- so the aim point never teleports behind the zombie.
	local waypointIndex = self.WaypointIndex
	while waypointIndex < #waypoints do
		if (self.RootPart.Position - waypoints[waypointIndex]).Magnitude <= WAYPOINT_REACH_RADIUS then
			waypointIndex += 1
		else
			break
		end
	end
	self.WaypointIndex = waypointIndex

	-- Aim one waypoint ahead of everything already reached for fluid steering.
	local steerPosition = waypoints[math.min(waypointIndex + 1, #waypoints)]

	-- Hop over small height mismatches along the route.
	if
		math.abs(self.RootPart.Position.Y - steerPosition.Y) > JUMP_HEIGHT_THRESHOLD
		and self.Humanoid.FloorMaterial ~= Enum.Material.Air
	then
		self.Humanoid.Jump = true
	end

	self.Humanoid:MoveTo(steerPosition)
end

function Zombie.PlaySound(self: Zombie)
	if table.isfrozen(self) then return end

	local sound = self.Model:FindFirstChildWhichIsA("Sound", true)
	if sound then
		sound:Play()
	end
end

return Zombie
