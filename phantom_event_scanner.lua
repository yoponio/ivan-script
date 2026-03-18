if not game:IsLoaded() then
	game.Loaded:Wait()
end

local scriptVersion = "phantom-autofarm-r1"

print("--- INICIANDO OSAKA " .. scriptVersion .. " (PHANTOM DEDICADO) ---")

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local LP = Players.LocalPlayer

local autoFarm = false
local scriptClosed = false
local activeTween = nil
local movementConn = nil
local loopThread = nil
local watchPromptConn = nil
local characterAddedConn = nil

local flySpeed = 420
local settleTime = 0.08
local orbTouchTime = 0.12
local depositDistance = 6
local promptRetryDelay = 0.18
local orbRefreshDelay = 0.05
local depositTargetCount = 100
local postTouchCountPolls = 8
local postTouchCountPollDelay = 0.05
local maxStoredLogs = 250

local storedLogs = {}
local statusLabel
local toggleButton
local copyLogsButton
local infoLabel

local getCharacter
local getHumanoid
local getRoot

local function updateCopyLogsButton()
	if copyLogsButton then
		copyLogsButton.Text = "COPIAR LOGS (" .. tostring(#storedLogs) .. ")"
	end
end

local function appendStoredLog(message)
	table.insert(storedLogs, message)
	if #storedLogs > maxStoredLogs then
		table.remove(storedLogs, 1)
	end
	print(message)
	if statusLabel then
		statusLabel.Text = message
	end
	updateCopyLogsButton()
end

local function debugLog(eventName, details)
	local message = string.format("[PHANTOM-AF][%.3f][%s] %s", os.clock(), tostring(eventName), tostring(details or ""))
	appendStoredLog(message)
end

local function copyLogsToClipboard()
	local payload = #storedLogs > 0 and table.concat(storedLogs, "\n") or "[PHANTOM-AF] no hay logs"
	for _, copyFn in ipairs({setclipboard, toclipboard}) do
		if type(copyFn) == "function" then
			local ok = pcall(copyFn, payload)
			if ok then
				debugLog("COPY", "logs copiados")
				return true
			end
		end
	end
	if type(Clipboard) == "table" and type(Clipboard.set) == "function" then
		local ok = pcall(function()
			Clipboard.set(payload)
		end)
		if ok then
			debugLog("COPY", "logs copiados")
			return true
		end
	end
	debugLog("COPY_FAIL", "sin API de clipboard")
	return false
end

local function safeIsA(instance, className)
	local ok, result = pcall(function()
		return instance and instance:IsA(className)
	end)
	return ok and result or false
end

local function safeName(instance)
	local ok, value = pcall(function()
		return instance.Name
	end)
	return ok and value or ""
end

local function safePath(instance)
	if not instance then
		return "nil"
	end
	local ok, path = pcall(function()
		return instance:GetFullName()
	end)
	return ok and path or tostring(instance)
end

local function safeText(instance, property)
	local ok, value = pcall(function()
		return instance[property]
	end)
	return ok and type(value) == "string" and value or ""
end

local function getModelPosition(instance)
	if not instance then
		return nil
	end
	local ok, value = pcall(function()
		if safeIsA(instance, "BasePart") then
			return instance.Position
		end
		if safeIsA(instance, "Attachment") then
			return instance.WorldPosition
		end
		if safeIsA(instance, "Model") then
			return instance:GetPivot().Position
		end
		local model = instance:FindFirstAncestorWhichIsA("Model")
		if model then
			return model:GetPivot().Position
		end
		local part = instance:FindFirstAncestorWhichIsA("BasePart")
		if part then
			return part.Position
		end
		return nil
	end)
	return ok and value or nil
end

local function stopTween()
	if activeTween then
		pcall(function()
			activeTween:Cancel()
		end)
		activeTween = nil
	end
end

getCharacter = function()
	return LP.Character
end

getHumanoid = function()
	local character = getCharacter()
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

getRoot = function()
	local character = getCharacter()
	return character and character:FindFirstChild("HumanoidRootPart") or nil
end

local function setStatus(text)
	if infoLabel then
		infoLabel.Text = text
	end
end

local function setCollision(enabled)
	local character = getCharacter()
	if not character then
		return
	end
	for _, descendant in ipairs(character:GetDescendants()) do
		if safeIsA(descendant, "BasePart") then
			descendant.CanCollide = enabled
		end
	end
end

local function startMovementAssist()
	if movementConn then
		return
	end
	movementConn = RunService.Stepped:Connect(function()
		if autoFarm then
			setCollision(false)
		end
	end)
end

local function stopMovementAssist()
	if movementConn then
		movementConn:Disconnect()
		movementConn = nil
	end
	setCollision(true)
end

local function moveTo(targetCFrame, speed)
	local root = getRoot()
	if not root then
		return false
	end
	stopTween()
	local distance = (root.Position - targetCFrame.Position).Magnitude
	if distance <= 2 then
		root.CFrame = targetCFrame
		return true
	end
	local tweenInfo = TweenInfo.new(math.max(distance / math.max(speed or flySpeed, 1), 0.05), Enum.EasingStyle.Linear)
	activeTween = TweenService:Create(root, tweenInfo, {CFrame = targetCFrame})
	activeTween:Play()
	local completed = false
	local connection
	connection = activeTween.Completed:Connect(function()
		completed = true
		connection:Disconnect()
	end)
	while autoFarm and getRoot() == root and not completed do
		task.wait()
	end
	stopTween()
	return autoFarm
end

local function resolveOrbPart(model)
	if not model then
		return nil
	end
	local hitbox = model:FindFirstChild("Hitbox")
	if safeIsA(hitbox, "BasePart") then
		return hitbox
	end
	local part = model:FindFirstChild("Part")
	if safeIsA(part, "BasePart") then
		return part
	end
	if safeIsA(model, "BasePart") then
		return model
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if safeIsA(descendant, "BasePart") then
			return descendant
		end
	end
	return nil
end

local function isOrbModel(instance)
	local path = safePath(instance)
	local name = safeName(instance)
	if path:find("PhantomOrbParts", 1, true) then
		return true
	end
	if name:match("^PhantomOrb%d+$") then
		return true
	end
	return false
end

local function getNearestOrb()
	local root = getRoot()
	if not root then
		return nil
	end
	local bestModel = nil
	local bestPart = nil
	local bestDistance = math.huge
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if safeIsA(descendant, "Model") and isOrbModel(descendant) then
			local part = resolveOrbPart(descendant)
			if part then
				local distance = (root.Position - part.Position).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					bestModel = descendant
					bestPart = part
				end
			end
		end
	end
	return bestModel, bestPart, bestDistance
end

local function getDepositPrompt()
	local phantomMap = workspace:FindFirstChild("PhantomMap")
	local ghostCannon = phantomMap and phantomMap:FindFirstChild("GhostCannon")
	local part = ghostCannon and ghostCannon:FindFirstChild("Part")
	local prompts = part and part:FindFirstChild("Prompts")
	local prompt = prompts and prompts:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		return prompt
	end
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if safeIsA(descendant, "ProximityPrompt") then
			local actionText = string.lower(safeText(descendant, "ActionText"))
			local objectText = string.lower(safeText(descendant, "ObjectText"))
			local path = string.lower(safePath(descendant))
			if actionText:find("deposit orbs", 1, true) or objectText:find("ghost cannon", 1, true) or path:find("ghostcannon", 1, true) then
				return descendant
			end
		end
	end
	return nil
end

local function getHeldOrbCount()
	local prompt = getDepositPrompt()
	if not prompt then
		return 0, nil
	end
	local actionText = safeText(prompt, "ActionText")
	local amount = tonumber(string.match(actionText, "%((%d+)%)")) or 0
	return amount, prompt
end

local function waitForHeldCountUpdate(previousCount)
	local bestCount = previousCount or 0
	local bestPrompt = nil
	for _ = 1, postTouchCountPolls do
		local heldCount, prompt = getHeldOrbCount()
		if heldCount > bestCount then
			bestCount = heldCount
			bestPrompt = prompt
		end
		if heldCount >= depositTargetCount then
			return heldCount, prompt
		end
		task.wait(postTouchCountPollDelay)
	end
	return bestCount, bestPrompt
end

local function firePrompt(prompt)
	if not prompt then
		return false
	end
	if type(fireproximityprompt) == "function" then
		local ok = pcall(function()
			fireproximityprompt(prompt)
		end)
		if ok then
			return true
		end
	end
	local ok = pcall(function()
		prompt:InputHoldBegin()
		task.wait((prompt.HoldDuration or 0) + 0.1)
		prompt:InputHoldEnd()
	end)
	return ok
end

local function tryTouch(part)
	local root = getRoot()
	if not root or not part then
		return false
	end
	if type(firetouchinterest) == "function" then
		pcall(function()
			firetouchinterest(root, part, 0)
			task.wait(0.05)
			firetouchinterest(root, part, 1)
		end)
	end
	root.CFrame = part.CFrame + Vector3.new(0, 1.5, 0)
	task.wait(orbTouchTime)
	return true
end

local function getPromptStandCFrame(prompt)
	local position = getModelPosition(prompt) or getModelPosition(prompt.Parent)
	if not position then
		return nil
	end
	local root = getRoot()
	local lookTarget = position
	local approach = position + Vector3.new(0, 2.5, 0)
	if root then
		local direction = (root.Position - position)
		if direction.Magnitude < 1 then
			direction = Vector3.new(0, 0, -1)
		end
		approach = position + direction.Unit * depositDistance + Vector3.new(0, 2.0, 0)
		lookTarget = position
	end
	return CFrame.lookAt(approach, lookTarget)
end

local function depositOrbs()
	local heldCount, prompt = getHeldOrbCount()
	if not prompt then
		debugLog("DEPOSIT_FAIL", "no se encontro Ghost Cannon prompt")
		return false
	end
	if heldCount < depositTargetCount then
		debugLog("DEPOSIT_SKIP", string.format("held=%d target=%d", heldCount, depositTargetCount))
		return false
	end
	local standCFrame = getPromptStandCFrame(prompt)
	if standCFrame and not moveTo(standCFrame, flySpeed) then
		return false
	end
	task.wait(settleTime)
	local ok = firePrompt(prompt)
	if ok then
		debugLog("DEPOSIT", string.format("held=%d path=%s action=%s", heldCount, safePath(prompt), safeText(prompt, "ActionText")))
		return true
	end
	debugLog("DEPOSIT_FAIL", "no se pudo activar prompt")
	return false
end

local function collectOrbCycle()
	local heldCount = getHeldOrbCount()
	if heldCount >= depositTargetCount then
		depositOrbs()
		task.wait(promptRetryDelay)
		return
	end
	local orbModel, orbPart, distance = getNearestOrb()
	if not orbModel or not orbPart then
		debugLog("ORB_WAIT", string.format("sin orbes phantom held=%d/%d", heldCount, depositTargetCount))
		task.wait(orbRefreshDelay)
		return
	end
	debugLog("ORB_TARGET", string.format("held=%d/%d dist=%.1f path=%s", heldCount, depositTargetCount, distance, safePath(orbModel)))
	local approach = CFrame.new(orbPart.Position + Vector3.new(0, 2.0, 0))
	if not moveTo(approach, flySpeed) then
		return
	end
	task.wait(settleTime)
	tryTouch(orbPart)
	debugLog("ORB_TOUCH", safePath(orbPart))
	task.wait(orbTouchTime)
	local refreshedCount = waitForHeldCountUpdate(heldCount)
	if refreshedCount >= depositTargetCount then
		debugLog("ORB_CAP", string.format("held=%d/%d depositando ahora", refreshedCount, depositTargetCount))
		depositOrbs()
		task.wait(promptRetryDelay)
		return
	end
end

local function mainLoop()
	while autoFarm and not scriptClosed do
		local humanoid = getHumanoid()
		local root = getRoot()
		if not humanoid or humanoid.Health <= 0 or not root then
			debugLog("WAIT", "esperando character")
			task.wait(0.5)
		else
			collectOrbCycle()
		end
	end
	loopThread = nil
	stopTween()
	stopMovementAssist()
	if toggleButton and not scriptClosed then
		toggleButton.Text = "AUTO PHANTOM: OFF"
		toggleButton.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
	end
	setStatus("Listo para farmear Phantom")
end

local function setAutoFarm(state)
	autoFarm = state
	if toggleButton then
		toggleButton.Text = autoFarm and "AUTO PHANTOM: ON" or "AUTO PHANTOM: OFF"
		toggleButton.BackgroundColor3 = autoFarm and Color3.fromRGB(55, 110, 70) or Color3.fromRGB(45, 50, 55)
	end
	if autoFarm then
		setStatus("Juntando orbes hasta 100 para depositar en Ghost Cannon")
		startMovementAssist()
		if not loopThread then
			loopThread = task.spawn(mainLoop)
		end
		debugLog("RUN", "autofarm phantom activado")
	else
		stopTween()
		stopMovementAssist()
		debugLog("RUN", "autofarm phantom desactivado")
	end
end

local function onCharacterAdded(character)
	debugLog("RESPAWN", safePath(character))
	task.wait(1)
	if autoFarm then
		startMovementAssist()
	end
end

characterAddedConn = LP.CharacterAdded:Connect(onCharacterAdded)

local guiParent = (function()
	local ok, result = pcall(function()
		return gethui and gethui()
	end)
	if ok and result then
		return result
	end
	return game:GetService("CoreGui")
end)()

local oldGui = guiParent:FindFirstChild("PhantomAutofarmGui")
if oldGui then
	oldGui:Destroy()
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PhantomAutofarmGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = guiParent

local frame = Instance.new("Frame")
frame.Parent = screenGui
frame.Size = UDim2.new(0, 360, 0, 185)
frame.Position = UDim2.new(0.05, 0, 0.18, 0)
frame.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
frame.Active = true
frame.Draggable = true
frame.BorderSizePixel = 0
Instance.new("UICorner", frame)

local title = Instance.new("TextLabel")
title.Parent = frame
title.Size = UDim2.new(1, -90, 0, 28)
title.Position = UDim2.new(0, 10, 0, 8)
title.BackgroundTransparency = 1
title.Text = "PHANTOM AUTO " .. scriptVersion
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left

local closeButton = Instance.new("TextButton")
closeButton.Parent = frame
closeButton.Size = UDim2.new(0, 70, 0, 26)
closeButton.Position = UDim2.new(1, -80, 0, 9)
closeButton.BackgroundColor3 = Color3.fromRGB(120, 45, 45)
closeButton.Text = "CERRAR"
closeButton.TextColor3 = Color3.new(1, 1, 1)
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 12
closeButton.BorderSizePixel = 0
Instance.new("UICorner", closeButton)

statusLabel = Instance.new("TextLabel")
statusLabel.Parent = frame
statusLabel.Size = UDim2.new(1, -20, 0, 18)
statusLabel.Position = UDim2.new(0, 10, 0, 42)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Autofarm Phantom listo"
statusLabel.TextColor3 = Color3.fromRGB(215, 220, 225)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left

local function makeButton(text, x, y, width)
	local button = Instance.new("TextButton")
	button.Parent = frame
	button.Size = UDim2.new(0, width, 0, 28)
	button.Position = UDim2.new(0, x, 0, y)
	button.BackgroundColor3 = Color3.fromRGB(45, 50, 55)
	button.Text = text
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 12
	button.BorderSizePixel = 0
	Instance.new("UICorner", button)
	return button
end

toggleButton = makeButton("AUTO PHANTOM: ON", 10, 70, 170)
copyLogsButton = makeButton("COPIAR LOGS (0)", 186, 70, 140)

infoLabel = Instance.new("TextLabel")
infoLabel.Parent = frame
infoLabel.Size = UDim2.new(1, -20, 0, 42)
infoLabel.Position = UDim2.new(0, 10, 0, 108)
infoLabel.BackgroundTransparency = 1
infoLabel.Text = "Modo competitivo: junta PhantomOrbs hasta 100 y deposita en Ghost Cannon. Este archivo no es el scanner."
infoLabel.TextWrapped = true
infoLabel.TextColor3 = Color3.fromRGB(185, 190, 198)
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextSize = 11
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.TextYAlignment = Enum.TextYAlignment.Top

toggleButton.MouseButton1Click:Connect(function()
	setAutoFarm(not autoFarm)
end)

copyLogsButton.MouseButton1Click:Connect(copyLogsToClipboard)

closeButton.MouseButton1Click:Connect(function()
	scriptClosed = true
	setAutoFarm(false)
	stopTween()
	if characterAddedConn then
		characterAddedConn:Disconnect()
		characterAddedConn = nil
	end
	if watchPromptConn then
		watchPromptConn:Disconnect()
		watchPromptConn = nil
	end
	screenGui:Destroy()
end)

updateCopyLogsButton()
debugLog("BOOT", "Ghost Cannon=" .. safePath(getDepositPrompt()))
setAutoFarm(true)
