--!strict
-- TargetService: finds the nearest living player for NPC targeting.
local Players = game:GetService("Players")

-- Zombies never lose interest: detection is unlimited within the map.
local MAX_DETECTION_DISTANCE = math.huge

local TargetService = {}

-- Returns the closest living player within detection range, or nil if none qualify.
function TargetService.getNearestPlayer(originPart: BasePart?): Player?
	local nearestPlayer: Player? = nil
	local shortestDistance = MAX_DETECTION_DISTANCE

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then continue end

		local root = character:FindFirstChild("HumanoidRootPart")
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not root or not root:IsA("BasePart") then continue end
		if not humanoid or humanoid.Health <= 0 then continue end

		local distance = originPart and (originPart.Position - root.Position).Magnitude or 0
		if distance < shortestDistance then
			shortestDistance = distance
			nearestPlayer = player
		end
	end

	return nearestPlayer
end

return TargetService