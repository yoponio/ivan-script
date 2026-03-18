if not game:IsLoaded() then
	game.Loaded:Wait()
end

local scriptVersion = "phantom-autofarm-r1"

print("--- INICIANDO OSAKA " .. scriptVersion .. " (PHANTOM DEDICADO) ---")

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local LP = Players.LocalPlayer
local taskWait = task and task.wait or wait
local taskSpawn = task and task.spawn or function(callback)
	coroutine.wrap(callback)()
end
local zeroVector = Vector3.zero or Vector3.new(0, 0, 0)

local autoFarm = false
local scriptClosed = false
local activeTween = nil
local flyValue = Instance.new("CFrameValue")
local movementConn = nil
local loopThread = nil
local watchPromptConn = nil
local characterAddedConn = nil
local orbAddedConn = nil
local orbRemovingConn = nil
local basePos = nil
local depositPendingReset = false
local lastDepositCount = 0
local depositPendingSince = 0
local orbBlacklist = {}
local orbRegistry = {}
local lastOrbWaitLogAt = 0

local instantMove = true
local flySpeed = 420
local safeDepth = -60
local settleTime = 0.01
local orbTouchTime = 0.02
local depositDistance = 6
local promptRetryDelay = 0.05
local orbRefreshDelay = 0.01
local depositTargetCount = 100
local postTouchCountPolls = 6
local postTouchCountPollDelay = 0.02
local orbApproachHeight = -24
local depositApproachHeight = 3.0
local depositRetreatOffset = -30
local depositDirectOffset = -8
local depositPromptAttempts = 3
local depositSuccessPolls = 6
local depositSuccessPollDelay = 0.05
local orbRetreatOffset = -18
local remoteTouchAttempts = 2
local orbBlacklistSeconds = 8
local depositResetTimeout = 2.5
local orbWaitLogInterval = 0.4
local maxStoredLogs = 250

local storedLogs = {}
local statusLabel
local toggleButton
local copyLogsButton
local infoLabel

local getCharacter
local getHumanoid
local getRoot
local getDepositPrompt
local registerOrbModel
local unregisterOrbModel
local isOrbModel
local isOrbCandidate
local scanWorkspaceForNearestOrb

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

local function resolveBasePosition()
	local prompt = getDepositPrompt and getDepositPrompt() or nil
	local promptPosition = prompt and getModelPosition(prompt)
	if promptPosition then
		return promptPosition
	end
	local root = getRoot()
	return root and root.Position or nil
end

local function resolveTravelY(targetPos, forcedY)
	local fallenLimit = workspace.FallenPartsDestroyHeight or -500
	local minSafeY = fallenLimit + 25
	local referencePos = basePos or resolveBasePosition() or targetPos
	local safeY = forcedY or (referencePos.Y + safeDepth)
	safeY = math.max(safeY, minSafeY)
	return safeY
end

local function snapTo(goal)
	local character = getCharacter()
	local root = getRoot()
	if not root then
		return false
	end
	flyValue.Value = goal
	pcall(function()
		if character then
			character:PivotTo(goal)
		else
			root.CFrame = goal
		end
	end)
	root.AssemblyLinearVelocity = zeroVector
	root.AssemblyAngularVelocity = zeroVector
	return true
end

local function safeTravel(targetPos, finalYOffset, forcedSafeY)
	local root = getRoot()
	if not root then
		return false
	end
	local safeY = resolveTravelY(targetPos, forcedSafeY)
	local stage1 = CFrame.new(root.Position.X, safeY, root.Position.Z)
	local stage2 = CFrame.new(targetPos.X, safeY, targetPos.Z)
	local stage3 = CFrame.new(targetPos.X, targetPos.Y + (finalYOffset or 0), targetPos.Z)
	if not snapTo(stage1) then
		return false
	end
	taskWait()
	if not snapTo(stage2) then
		return false
	end
	taskWait()
	return snapTo(stage3)
end

local function retreatUnderPosition(targetPos, retreatOffset)
	if not targetPos then
		return false
	end
	local safeY = resolveTravelY(targetPos, targetPos.Y + (retreatOffset or depositRetreatOffset))
	return snapTo(CFrame.new(targetPos.X, safeY, targetPos.Z))
end

local function startMovementAssist()
	if movementConn then
		return
	end
	local root = getRoot()
	if root then
		flyValue.Value = root.CFrame
	end
	movementConn = RunService.Stepped:Connect(function()
		local rootPart = getRoot()
		if not rootPart then
			return
		end
		if autoFarm then
			setCollision(false)
			rootPart.CFrame = flyValue.Value
			rootPart.AssemblyLinearVelocity = zeroVector
			rootPart.AssemblyAngularVelocity = zeroVector
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
	if instantMove then
		safeTravel(targetCFrame.Position, 0)
		return autoFarm
	end
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
		taskWait()
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

scanWorkspaceForNearestOrb = function(root)
	local bestModel = nil
	local bestPart = nil
	local bestDistance = math.huge
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if isOrbCandidate(descendant) then
			local path = safePath(descendant)
			if not isBlacklisted(path) then
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
	end
	if bestModel then
		registerOrbModel(bestModel)
	end
	return bestModel, bestPart, bestDistance
end

isOrbCandidate = function(instance)
	if not instance then
		return false
	end
	if safeIsA(instance, "Model") or safeIsA(instance, "Folder") or safeIsA(instance, "BasePart") then
		return isOrbModel(instance)
	end
	return false
end

registerOrbModel = function(model)
	if not isOrbCandidate(model) then
		return
	end
	orbRegistry[safePath(model)] = model
end

unregisterOrbModel = function(model)
	if not model then
		return
	end
	orbRegistry[safePath(model)] = nil
end

local function rebuildOrbRegistry()
	for path in pairs(orbRegistry) do
		orbRegistry[path] = nil
	end
	local sources = {
		workspace:FindFirstChild("PhantomEventParts"),
		workspace:FindFirstChild("PhantomOrbParts"),
		workspace,
	}
	for _, source in ipairs(sources) do
		if source then
			for _, descendant in ipairs(source:GetDescendants()) do
				if isOrbCandidate(descendant) then
					registerOrbModel(descendant)
				end
			end
		end
	end
end

local function ensureOrbWatchers()
	if orbAddedConn and orbRemovingConn then
		return
	end
	rebuildOrbRegistry()
	orbAddedConn = workspace.DescendantAdded:Connect(function(descendant)
		if isOrbCandidate(descendant) then
			registerOrbModel(descendant)
		end
	end)
	orbRemovingConn = workspace.DescendantRemoving:Connect(function(descendant)
		if isOrbCandidate(descendant) then
			unregisterOrbModel(descendant)
		end
	end)
end

local function isBlacklisted(path)
	local expiresAt = orbBlacklist[path]
	if not expiresAt then
		return false
	end
	if os.clock() >= expiresAt then
		orbBlacklist[path] = nil
		return false
	end
	return true
end

local function blacklistOrb(instance, reason)
	local path = safePath(instance)
	orbBlacklist[path] = os.clock() + orbBlacklistSeconds
	debugLog("ORB_BLACKLIST", string.format("path=%s reason=%s", path, tostring(reason or "n/a")))
end

isOrbModel = function(instance)
	local path = safePath(instance)
	local name = safeName(instance)
	if path:find("PhantomOrbParts", 1, true) then
		return true
	end
	if path:find("PhantomEventParts", 1, true) and name:find("PhantomOrb", 1, true) then
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
	local registryCount = 0
	local availableCount = 0
	for path, model in pairs(orbRegistry) do
		registryCount = registryCount + 1
		if typeof(model) ~= "Instance" or model.Parent == nil then
			orbRegistry[path] = nil
		elseif not isBlacklisted(path) then
			availableCount = availableCount + 1
			local part = resolveOrbPart(model)
			if part then
				local distance = (root.Position - part.Position).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					bestModel = model
					bestPart = part
				end
			else
				orbRegistry[path] = nil
			end
		end
	end
	if not bestModel then
		if availableCount == 0 and registryCount > 0 then
			for path in pairs(orbBlacklist) do
				orbBlacklist[path] = nil
			end
		end
		rebuildOrbRegistry()
		registryCount = 0
		for path, model in pairs(orbRegistry) do
			registryCount = registryCount + 1
			if typeof(model) ~= "Instance" or model.Parent == nil then
				orbRegistry[path] = nil
			elseif not isBlacklisted(path) then
				local part = resolveOrbPart(model)
				if part then
					local distance = (root.Position - part.Position).Magnitude
					if distance < bestDistance then
						bestDistance = distance
						bestModel = model
						bestPart = part
					end
				else
					orbRegistry[path] = nil
				end
			end
		end
		if not bestModel then
			bestModel, bestPart, bestDistance = scanWorkspaceForNearestOrb(root)
			if bestModel then
				debugLog("ORB_SCAN_RECOVER", string.format("path=%s dist=%.1f", safePath(bestModel), bestDistance))
			else
				debugLog("ORB_REGISTRY", string.format("registry=%d blacklisted=%d", registryCount, next(orbBlacklist) and 1 or 0))
			end
		end
	end
	return bestModel, bestPart, bestDistance
end

getDepositPrompt = function()
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

local function isDepositResetComplete()
	if not depositPendingReset then
		return true
	end
	local heldCount = getHeldOrbCount()
	if heldCount == 0 or heldCount < lastDepositCount then
		depositPendingReset = false
		lastDepositCount = 0
		depositPendingSince = 0
		debugLog("DEPOSIT_RESET", "contador actualizado")
		return true
	end
	if depositPendingSince > 0 and (os.clock() - depositPendingSince) >= depositResetTimeout then
		depositPendingReset = false
		lastDepositCount = heldCount
		depositPendingSince = 0
		debugLog("DEPOSIT_TIMEOUT", string.format("held=%d sin refresh del prompt", heldCount))
		return true
	end
	return false
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
		taskWait(postTouchCountPollDelay)
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
		taskWait((prompt.HoldDuration or 0) + 0.1)
		prompt:InputHoldEnd()
	end)
	return ok
end

local function waitForDepositSuccess(previousCount)
	local lowestCount = previousCount or math.huge
	local latestPrompt = nil
	for _ = 1, depositSuccessPolls do
		local heldCount, prompt = getHeldOrbCount()
		latestPrompt = prompt or latestPrompt
		if heldCount < lowestCount then
			lowestCount = heldCount
		end
		if heldCount == 0 or heldCount < (previousCount or math.huge) then
			return true, heldCount, latestPrompt
		end
		taskWait(depositSuccessPollDelay)
	end
	return false, lowestCount, latestPrompt
end

local function tryTouch(part)
	local root = getRoot()
	if not root or not part then
		return false
	end
	root.AssemblyLinearVelocity = zeroVector
	root.AssemblyAngularVelocity = zeroVector
	safeTravel(part.Position, orbApproachHeight)
	if type(firetouchinterest) == "function" then
		for _ = 1, remoteTouchAttempts do
			pcall(function()
				firetouchinterest(root, part, 0)
				taskWait()
				firetouchinterest(root, part, 1)
			end)
		end
	else
		root.CFrame = part.CFrame + Vector3.new(0, orbApproachHeight, 0)
	end
	retreatUnderPosition(part.Position, orbRetreatOffset)
	taskWait(orbTouchTime)
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
		approach = position + direction.Unit * depositDistance + Vector3.new(0, depositApproachHeight, 0)
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
	local promptPosition = getModelPosition(prompt) or getModelPosition(prompt.Parent)
	for attempt = 1, depositPromptAttempts do
		local ok = firePrompt(prompt)
		if ok then
			local success, newCount = waitForDepositSuccess(heldCount)
			if success then
				depositPendingReset = true
				lastDepositCount = heldCount
				depositPendingSince = os.clock()
				debugLog("DEPOSIT", string.format("held=%d path=%s action=%s try=%d newHeld=%d", heldCount, safePath(prompt), safeText(prompt, "ActionText"), attempt, newCount))
				if promptPosition then
					retreatUnderPosition(promptPosition, depositRetreatOffset)
				end
				return true
			end
		end

		if promptPosition then
			snapTo(CFrame.new(promptPosition + Vector3.new(0, depositDirectOffset, 0)))
			taskWait(settleTime)
		end
	end
	debugLog("DEPOSIT_FAIL", string.format("no se pudo activar prompt held=%d", heldCount))
	return false
end

local function collectOrbCycle()
	if depositPendingReset then
		if not isDepositResetComplete() then
			taskWait(promptRetryDelay)
			return
		end
	end
	local heldCount = getHeldOrbCount()
	if heldCount >= depositTargetCount then
		depositOrbs()
		taskWait(promptRetryDelay)
		return
	end
	local orbModel, orbPart, distance = getNearestOrb()
	if not orbModel or not orbPart then
		if (os.clock() - lastOrbWaitLogAt) >= orbWaitLogInterval then
			lastOrbWaitLogAt = os.clock()
			debugLog("ORB_WAIT", string.format("sin orbes phantom held=%d/%d", heldCount, depositTargetCount))
		end
		taskWait(orbRefreshDelay)
		return
	end
	debugLog("ORB_TARGET", string.format("held=%d/%d dist=%.1f path=%s", heldCount, depositTargetCount, distance, safePath(orbModel)))
	tryTouch(orbPart)
	debugLog("ORB_TOUCH", safePath(orbPart))
	taskWait(orbTouchTime)
	local refreshedCount = waitForHeldCountUpdate(heldCount)
	if refreshedCount <= heldCount then
		blacklistOrb(orbModel, "sin aumento de contador")
		taskWait(orbRefreshDelay)
		return
	end
	if refreshedCount >= depositTargetCount then
		debugLog("ORB_CAP", string.format("held=%d/%d depositando ahora", refreshedCount, depositTargetCount))
		depositOrbs()
		taskWait(promptRetryDelay)
		return
	end
end

local function mainLoop()
	while autoFarm and not scriptClosed do
		local humanoid = getHumanoid()
		local root = getRoot()
		if not humanoid or humanoid.Health <= 0 or not root then
			debugLog("WAIT", "esperando character")
			taskWait(0.5)
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
		basePos = resolveBasePosition() or basePos
		setStatus("Juntando orbes hasta 100 para depositar en Ghost Cannon")
		ensureOrbWatchers()
		startMovementAssist()
		if not loopThread then
			loopThread = taskSpawn(mainLoop)
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
	taskWait(1)
	local root = getRoot()
	if root then
		flyValue.Value = root.CFrame
	end
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
	if orbAddedConn then
		orbAddedConn:Disconnect()
		orbAddedConn = nil
	end
	if orbRemovingConn then
		orbRemovingConn:Disconnect()
		orbRemovingConn = nil
	end
	screenGui:Destroy()
end)

updateCopyLogsButton()
debugLog("BOOT", "Ghost Cannon=" .. safePath(getDepositPrompt()))
basePos = resolveBasePosition() or basePos
ensureOrbWatchers()
setAutoFarm(true)
