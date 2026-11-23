-- Tumble Circuit: Chaos Drop — client entry point (Phase A1)

local MarbleController = require(script:WaitForChild("MarbleController"))
local Hud = require(script:WaitForChild("Hud"))
local TouchFallback = require(script:WaitForChild("TouchFallback"))

MarbleController.start()

Hud.start({
	onReset = MarbleController.resetToCheckpoint,
	onRestart = MarbleController.restartRun,
})

TouchFallback.start(MarbleController)
