--!strict
-- Behavior: bootstrap script. Spawns the toggle button that runs the crowd simulation.
local Button = require(script.Parent:WaitForChild("Button"))

local BUTTON_POSITION = Vector3.new(10, 0, 2)

if not Button.new(BUTTON_POSITION) then
	warn("Crowd simulation toggle failed to initialize.")
end
