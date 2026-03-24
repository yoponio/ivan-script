--[[
BRAINROT FARMER V234 - POST TRIGGER RELEASE
Arquitectura: FSM Estricta, DEAD terminal, recovery estable y BURST sellado seguro

CAMBIOS V234:
1. DEAD es terminal y solo se libera con CharacterAdded estable.
2. Se separa salud minima de arranque y salud minima de recuperacion.
3. El burst usa hold real cuando el prompt lo requiere.
4. Despues del trigger real se libera el character para dejar pasar el carry del servidor.
5. Se confirma pickup por HoldWeld, RenderedBrainrot en character y reparent al jugador.
]]

local Players = game:GetService("Players")
local RS = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local UIS = game:GetService("UserInputService")

local player = Players.LocalPlayer
local scriptName = "IvanForensicsV234"

if _G.IvanFarmer_Cleanup then _G.IvanFarmer_Cleanup() end

-- ==============================================================================
-- 1. ESTRUCTURAS BÁSICAS Y UTILIDADES
-- ==============================================================================
local MAX_LOGS = 60
local Connections = {}
local Threads = {}

local function safeConnect(event, callback)
    local conn = event:Connect(callback)
    table.insert(Connections, conn)
    return conn
end

local Config = {
    Activo = false, 
    Mutacion = nil, 
    Y_Transito = -3.00, 
    Y_Cobro = -4.00,
    Distancia = 3.0, 
    Velocidad = 400, 
    Home = nil,
    HomeSafetyMargin = 2.0,
    StableVyEpsilon = 1.5,
    StablePosEpsilon = 0.35,
    ReleaseStableFrames = 8,
    HomeStableFrames = 6,
    RespawnStableFrames = 12,
    RespawnGuardSeconds = 1.75,
    EmergencyGuardSeconds = 2.25,
    MinStartHealth = 50.0,
    MinRecoverHealth = 1.0,
    BurstMode = "SAFE_PROMPT_HEIGHT",
    BurstProbeFree = false,
    BurstFireEvery = 0.10,
    BurstHoldPadding = 0.25,
    AutoReleaseRetryEvery = 0.40,
    BurstConfirmFrames = 3,
    BurstPostTriggerGrace = 0.22,
    BurstFallbackFireInHold = false,
    BurstCarryConfirmWindow = 0.90,
    BurstPromptMaxDistance = 100,
    BurstRapidAttempts = 4,
    BurstHoldAttempts = 2,
    BurstRapidAttemptDelay = 0.08,
    BurstPostFireConfirmWindow = 4.00,
    BurstPromptSetupDelay = 0.15,
    BurstClaimSettleWindow = 4.00,
    BurstHoldExtra = 0.12,
    BurstPromptRootOffset = 2.80,
    BurstPostTriggerRelease = true,
    BurstFreeInteractDelay = 0.06,
    BurstReSnapDistance = 2.5,
    TargetRetryCooldown = 2.75,
    TargetSuccessCooldown = 1.50,
    BurstSoftResetReasons = {
        NO_PROMPT = true,
        PROMPT_NOT_CONFIRMED = true,
        TRIGGER_WITHOUT_PICKUP_CONFIRM = true,
        TARGET_VANISHED_PRE_CONFIRM = true,
        CLAIM_WITHOUT_CARRY_CONFIRM = true,
        CLAIM_SETTLE_LOST = true
    }
}

-- ==============================================================================
-- 2. CAPA UI & LOGGER (Ring Buffer)
-- ==============================================================================
local UI = { LogLabels = {}, ButtonPool = {}, Minimized = false }
local Logger = { 
    Buffer = table.create(400, ""), LogIndex = 1,
    Snapshots = table.create(30), SnapIndex = 1 
}

local sg = Instance.new("ScreenGui", CoreGui); sg.Name = scriptName
local main = Instance.new("Frame", sg); main.Name = "Main"; main.Size = UDim2.new(0, 260, 0, 315); main.Position = UDim2.new(0.5, -130, 0.28, 0); main.BackgroundColor3 = Color3.fromRGB(15, 15, 15); main.BorderSizePixel = 1; main.ClipsDescendants = true
main.Active = true

local topBar = Instance.new("Frame", main); topBar.Name = "TopBar"; topBar.Size = UDim2.new(1, 0, 0, 30); topBar.BackgroundColor3 = Color3.fromRGB(0, 160, 80)
topBar.Active = true

local title = Instance.new("TextLabel", topBar); title.Size = UDim2.new(1, -34, 1, 0); title.Position = UDim2.new(0, 6, 0, 0); title.BackgroundTransparency = 1; title.Text = "V234 - POST TRIGGER RELEASE"; title.TextColor3 = Color3.new(1,1,1); title.Font = Enum.Font.SourceSansBold; title.TextSize = 14; title.TextXAlignment = Enum.TextXAlignment.Left
local btnToggle = Instance.new("TextButton", topBar); btnToggle.Size = UDim2.new(0, 28, 0, 22); btnToggle.Position = UDim2.new(1, -31, 0, 4); btnToggle.Text = "−"; btnToggle.BackgroundColor3 = Color3.fromRGB(40, 40, 40); btnToggle.TextColor3 = Color3.new(1,1,1)

local logBox = Instance.new("ScrollingFrame", main); logBox.Name = "LogBox"; logBox.Size = UDim2.new(0.9, 0, 0, 130); logBox.Position = UDim2.new(0.05, 0, 0, 128); logBox.BackgroundColor3 = Color3.fromRGB(5, 5, 5); logBox.ScrollBarThickness = 4
local logLayout = Instance.new("UIListLayout", logBox); logLayout.SortOrder = Enum.SortOrder.LayoutOrder; logLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom

local mutScroll = Instance.new("ScrollingFrame", main); mutScroll.Size = UDim2.new(0.9, 0, 0, 82); mutScroll.Position = UDim2.new(0.05, 0, 0, 38); mutScroll.BackgroundColor3 = Color3.fromRGB(20, 20, 20); mutScroll.ScrollBarThickness = 4
local mutLayout = Instance.new("UIListLayout", mutScroll); mutLayout.Padding = UDim.new(0, 2)

local footer = Instance.new("Frame", main); footer.Size = UDim2.new(1, 0, 0, 50); footer.Position = UDim2.new(0, 0, 1, -50); footer.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
local btnAction = Instance.new("TextButton", footer); btnAction.Size = UDim2.new(0.55, 0, 0, 36); btnAction.Position = UDim2.new(0.05, 0, 0, 7); btnAction.Text = "INICIAR"; btnAction.BackgroundColor3 = Color3.fromRGB(0, 150, 50); btnAction.TextColor3 = Color3.new(1,1,1); btnAction.Font = Enum.Font.SourceSansBold
local btnCopy = Instance.new("TextButton", footer); btnCopy.Size = UDim2.new(0.3, 0, 0, 36); btnCopy.Position = UDim2.new(0.65, 0, 0, 7); btnCopy.Text = "COPY"; btnCopy.BackgroundColor3 = Color3.fromRGB(60, 60, 60); btnCopy.TextColor3 = Color3.new(1,1,1); btnCopy.Font = Enum.Font.SourceSansBold

for i = 1, MAX_LOGS do
    local lbl = Instance.new("TextLabel", logBox)
    lbl.Size = UDim2.new(1, 0, 0, 14); lbl.BackgroundTransparency = 1; lbl.Text = ""
    lbl.TextColor3 = Color3.new(1,1,1); lbl.TextSize = 9; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.LayoutOrder = i
    UI.LogLabels[i] = lbl
end

function Logger:Log(msg, color)
    local line = "["..os.date("%X").."] "..msg
    self.Buffer[self.LogIndex] = line
    self.LogIndex = (self.LogIndex % 400) + 1
    
    for i = 1, MAX_LOGS - 1 do
        UI.LogLabels[i].Text = UI.LogLabels[i+1].Text; UI.LogLabels[i].TextColor3 = UI.LogLabels[i+1].TextColor3
    end
    UI.LogLabels[MAX_LOGS].Text = line; UI.LogLabels[MAX_LOGS].TextColor3 = color or Color3.new(1,1,1)
    
    logBox.CanvasSize = UDim2.new(0, 0, 0, logLayout.AbsoluteContentSize.Y)
    logBox.CanvasPosition = Vector2.new(0, 99999)
end

function Logger:Dump(reason)
    self:Log("!!! BLACKBOX DUMP: " .. reason, Color3.new(1, 0.3, 0.3))
    for i = 1, 30 do
        local index = (self.SnapIndex + i - 2) % 30 + 1
        local s = self.Snapshots[index]
        if s then
            local stateA = s.anchored and "ANC" or "FREE"
            self:Log(string.format("-- T-%.2fs | HP:%.0f | Y:%.1f | Vy:%.1f | Ph:%s | DXZ:%.1f | %s",
                tick() - s.t, s.hp, s.y, s.vy, s.phase, s.distXZ, stateA), Color3.new(0.8, 0.8, 0.8))
        end
    end
end

-- ==============================================================================
-- 3. CAPA DE MOTOR FÍSICO Y GHOST MODE
-- ==============================================================================
local Motor = { GhostCache = {} }
local TargetCooldowns = setmetatable({}, { __mode = "k" })
local FSM = {
    Phase = "IDLE",
    StateID = 0,
    Session = 0,
    TargetRoot = nil,
    TargetPrompt = nil,
    EmergencyTicks = 0,
    LastEmergencyAt = 0,
    LastRespawnAt = 0,
    DeadLatch = false,
    LastStartBlockLogAt = 0,
    LastStabilityPos = nil,
    PendingSafeRelease = false,
    PendingSafeReleaseReason = nil,
    LastReleaseAttemptAt = 0
}

local function GetPromptWorldPosition(prompt, fallback)
    if not prompt then return fallback end

    local parent = prompt.Parent
    if parent then
        if parent:IsA("Attachment") then
            return parent.WorldPosition
        end
        if parent:IsA("BasePart") then
            return parent.Position
        end
        if parent:IsA("Model") and parent.PrimaryPart then
            return parent.PrimaryPart.Position
        end
    end

    return fallback
end

function FSM:GetValidEntity()
    local char = player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not hrp or not hum or hum.Health <= 0 then return nil end
    return char, hrp, hum
end

function FSM:ClearTargets()
    self.TargetRoot = nil
    self.TargetPrompt = nil
end

function FSM:GetTargetCooldownRemaining(targetRoot, prompt)
    local now = tick()
    local rootUntil = (targetRoot and TargetCooldowns[targetRoot]) or 0
    local promptUntil = (prompt and TargetCooldowns[prompt]) or 0
    local expiresAt = math.max(rootUntil, promptUntil)
    if expiresAt > now then
        return expiresAt - now
    end
    return 0
end

function FSM:IsTargetCoolingDown(targetRoot, prompt)
    return self:GetTargetCooldownRemaining(targetRoot, prompt) > 0
end

function FSM:MarkTargetCooldown(targetRoot, prompt, seconds, reason)
    local cooldown = math.max(seconds or 0, 0)
    if cooldown <= 0 then return end

    local expiresAt = tick() + cooldown
    if targetRoot then
        TargetCooldowns[targetRoot] = math.max(TargetCooldowns[targetRoot] or 0, expiresAt)
    end
    if prompt then
        TargetCooldowns[prompt] = math.max(TargetCooldowns[prompt] or 0, expiresAt)
    end

    Logger:Log(string.format("[TARGET_COOLDOWN] %.2fs (%s)", cooldown, tostring(reason or "n/a")), Color3.new(1, 0.7, 0))
end

local function GetOwnedToolCounts()
    local total = 0
    local totalByName = {}
    local backpackByName = {}
    local characterByName = {}
    local backpack = player:FindFirstChildOfClass("Backpack")
    local character = player.Character

    local function collect(container, bucket)
        if not container then return end
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Tool") then
                total += 1
                bucket[child.Name] = (bucket[child.Name] or 0) + 1
                totalByName[child.Name] = (totalByName[child.Name] or 0) + 1
            end
        end
    end

    collect(backpack, backpackByName)
    collect(character, characterByName)

    return {
        total = total,
        totalByName = totalByName,
        backpackByName = backpackByName,
        characterByName = characterByName,
    }
end

local function GetOwnedToolTotal()
    return GetOwnedToolCounts().total
end

local function GetPositiveToolDelta(beforeMap, afterMap)
    local delta = 0
    local names = {}

    for name, afterCount in pairs(afterMap or {}) do
        local beforeCount = (beforeMap and beforeMap[name]) or 0
        if afterCount > beforeCount then
            local diff = afterCount - beforeCount
            delta += diff
            table.insert(names, string.format("%s(+%d)", name, diff))
        end
    end

    table.sort(names)
    return delta, table.concat(names, ", ")
end

local function GetChildSignatureCounts(container)
    local counts = {}
    if not container then return counts end

    for _, child in ipairs(container:GetChildren()) do
        local key = string.format("%s|%s", child.ClassName, child.Name)
        counts[key] = (counts[key] or 0) + 1
    end

    return counts
end

local function GetSignatureDelta(beforeMap, afterMap)
    local names = {}

    for key, afterCount in pairs(afterMap or {}) do
        local beforeCount = (beforeMap and beforeMap[key]) or 0
        if afterCount > beforeCount then
            local diff = afterCount - beforeCount
            table.insert(names, string.format("%s(+%d)", key, diff))
        end
    end

    table.sort(names)
    return #names > 0, table.concat(names, ", ")
end

local function IsCarryRelevantDescendant(instance)
    if not instance then return false end
    if instance:IsA("Tool") or instance:IsA("Weld") or instance:IsA("WeldConstraint") or instance:IsA("Attachment") or instance:IsA("Model") then
        return true
    end

    local loweredName = string.lower(instance.Name)
    if loweredName:find("brainrot", 1, true) or loweredName:find("hold", 1, true) or loweredName:find("weld", 1, true) or loweredName:find("carry", 1, true) then
        return true
    end

    return false
end

local function GetRelevantDescendantSignatureCounts(container)
    local counts = {}
    if not container then return counts end

    for _, descendant in ipairs(container:GetDescendants()) do
        if IsCarryRelevantDescendant(descendant) then
            local key = string.format("%s|%s", descendant.ClassName, descendant.Name)
            counts[key] = (counts[key] or 0) + 1
        end
    end

    return counts
end

local function FormatSignalCounts(signalMap, limit)
    local items = {}
    for key, count in pairs(signalMap or {}) do
        if count > 1 then
            table.insert(items, string.format("%s(x%d)", key, count))
        else
            table.insert(items, key)
        end
    end

    table.sort(items)
    if limit and #items > limit then
        while #items > limit do
            table.remove(items)
        end
    end
    return table.concat(items, ", ")
end

function FSM:RequestSafeRelease(reason)
    if self.DeadLatch or self.Phase == "DEAD" then
        return
    end

    self.PendingSafeRelease = true
    self.PendingSafeReleaseReason = reason or "Deferred Release"
end

function FSM:IsHomeCFrameSafe(homeCF)
    return homeCF and homeCF.Position.Y > (Config.Y_Transito + Config.HomeSafetyMargin)
end

function FSM:CheckStabilitySample(hrp, hum, previousPos, opts)
    opts = opts or {}

    if not hrp or not hrp.Parent or not hum or hum.Health <= 0 then
        return false, "NO_ENTITY", previousPos
    end

    local minY = opts.minY or (Config.Y_Transito + 1.0)
    local minHealth = opts.minHealth or Config.MinRecoverHealth
    local requireAnchored = opts.requireAnchored == true
    local vy = math.abs(hrp.AssemblyLinearVelocity.Y)
    local pos = hrp.Position
    local delta = previousPos and (pos - previousPos).Magnitude or 0

    if requireAnchored and not hrp.Anchored then
        return false, "NOT_ANCHORED", pos
    end
    if pos.Y <= minY then
        return false, "LOW_Y", pos
    end
    if hum.Health < minHealth then
        return false, "LOW_HP", pos
    end
    if vy > Config.StableVyEpsilon then
        return false, "HIGH_VY", pos
    end
    if previousPos and delta > Config.StablePosEpsilon then
        return false, "POS_DRIFT", pos
    end

    return true, "STABLE", pos
end

function FSM:WaitForStableWindow(requiredFrames, opts)
    local stableFrames = 0
    local previousPos = nil
    local maxFrames = (opts and opts.maxFrames) or math.max(requiredFrames * 5, requiredFrames + 8)
    local lastReason = "INIT"

    for _ = 1, maxFrames do
        local _, hrp, hum = self:GetValidEntity()
        if not hrp or not hum then
            return false, "NO_ENTITY"
        end

        local ok, reason, nextPos = self:CheckStabilitySample(hrp, hum, previousPos, opts)
        previousPos = nextPos
        if ok then
            stableFrames += 1
            if stableFrames >= requiredFrames then
                return true, "STABLE"
            end
        else
            stableFrames = 0
            lastReason = reason
        end

        RS.Heartbeat:Wait()
    end

    return false, lastReason
end

function FSM:IsRoutineBlocked()
    local now = tick()

    if self.DeadLatch or self.Phase == "DEAD" then
        return true, "DEAD_LATCH"
    end
    if (now - (self.LastRespawnAt or 0)) < Config.RespawnGuardSeconds then
        return true, "RESPAWN_GUARD"
    end
    if (now - (self.LastEmergencyAt or 0)) < Config.EmergencyGuardSeconds then
        return true, "EMERGENCY_GUARD"
    end

    local _, hrp, hum = self:GetValidEntity()
    if not hrp or not hum then
        return true, "NO_ENTITY"
    end
    if hum.Health < Config.MinStartHealth then
        return true, "LOW_HP_START"
    end

    local stable, reason = self:CheckStabilitySample(hrp, hum, nil, {
        minY = Config.Y_Transito + 1.0,
        minHealth = Config.MinStartHealth,
        requireAnchored = true
    })
    if not stable then
        return true, reason
    end

    return false, "READY"
end

function Motor:StopMotion(hrp)
    if not hrp then return end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
end

function Motor:SetAnchored(hrp, anchored)
    if not hrp then return end
    self:StopMotion(hrp)
    hrp.Anchored = anchored and true or false
    if anchored then
        self:StopMotion(hrp)
    end
end

function Motor:SealCharacter(hrp)
    self:SetAnchored(hrp, true)
end

function Motor:ReleaseCharacter(hrp)
    self:SetAnchored(hrp, false)
end

function Motor:TeleportCharacter(char, hrp, targetCFrame, anchoredAfter)
    if not char or not hrp or not targetCFrame then return false end
    self:SealCharacter(hrp)
    char:PivotTo(targetCFrame)
    RS.Heartbeat:Wait()
    self:StopMotion(hrp)
    hrp.Anchored = anchoredAfter ~= false
    return true
end

function Motor:SetGhostMode(enable)
    local char = FSM:GetValidEntity()
    if not char then return end
    if enable then
        table.clear(self.GhostCache)
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                self.GhostCache[part] = { CanCollide = part.CanCollide, CanTouch = part.CanTouch }
                part.CanCollide = false; part.CanTouch = false
            end
        end
    else
        for part, props in pairs(self.GhostCache) do
            if part and part.Parent then
                part.CanCollide = props.CanCollide; part.CanTouch = props.CanTouch
            end
        end
        table.clear(self.GhostCache)
    end
end

-- ==============================================================================
-- 4. FUNCIONES DE RECUPERACIÓN Y SEGURIDAD (LAS QUE PEDISTE)
-- ==============================================================================
function FSM:ReleaseCharacterIfSafe(context)
    local char, hrp, hum = self:GetValidEntity()
    if not hrp then return false, "NO_ENTITY" end

    if self.Phase ~= "IDLE" then
        Logger:Log("[RELEASE_BLOCKED] Phase=" .. self.Phase, Color3.new(1, 0.5, 0))
        return false, "PHASE_" .. self.Phase
    end

    if self.DeadLatch then
        Logger:Log("[RELEASE_BLOCKED] DEAD_LATCH", Color3.new(1, 0.3, 0.3))
        return false, "DEAD_LATCH"
    end

    if (tick() - (self.LastRespawnAt or 0)) < Config.RespawnGuardSeconds then
        Logger:Log("[RELEASE_BLOCKED] RESPAWN_GUARD", Color3.new(1, 0.5, 0))
        return false, "RESPAWN_GUARD"
    end

    if (tick() - (self.LastEmergencyAt or 0)) < Config.EmergencyGuardSeconds then
        Logger:Log("[RELEASE_BLOCKED] EMERGENCY_GUARD", Color3.new(1, 0.5, 0))
        return false, "EMERGENCY_GUARD"
    end

    local ok, reason = self:WaitForStableWindow(Config.ReleaseStableFrames, {
        minY = Config.Y_Transito + 1.0,
        minHealth = Config.MinRecoverHealth,
        requireAnchored = true,
        maxFrames = 48
    })

    if ok then
        Motor:ReleaseCharacter(hrp)
        self.PendingSafeRelease = false
        self.PendingSafeReleaseReason = nil
        Logger:Log("[RELEASE_OK] " .. tostring(context), Color3.new(0, 1, 0))
        return true, "OK"
    else
        Motor:SealCharacter(hrp)
        Logger:Log("[RELEASE_BLOCKED] " .. tostring(reason), Color3.new(1, 0.5, 0))
        return false, reason
    end
end

function FSM:SaveHomeIfSafe(hrp)
    local ok, reason = self:WaitForStableWindow(Config.HomeStableFrames, {
        minY = Config.Y_Transito + Config.HomeSafetyMargin,
        minHealth = Config.MinRecoverHealth,
        requireAnchored = true,
        maxFrames = 36
    })

    if ok then
        Config.Home = hrp.CFrame
        Logger:Log("Home Fijado: Y=" .. string.format("%.1f", Config.Home.Y), Color3.new(0, 1, 0))
    else
        Logger:Log("[HOME_REJECTED] " .. tostring(reason), Color3.new(1, 0.5, 0))
    end
end

function FSM:RecoverToSafeHome(hrp, char)
    Motor:SealCharacter(hrp)
    if self:IsHomeCFrameSafe(Config.Home) then
        Motor:TeleportCharacter(char, hrp, Config.Home + Vector3.new(0, 3, 0), true)
        Logger:Log("[RECOVERY] Teleport a Home Seguro", Color3.new(0, 1, 1))
    else
        Motor:TeleportCharacter(char, hrp, hrp.CFrame + Vector3.new(0, math.abs(hrp.Position.Y) + 15, 0), true)
        Logger:Log("[RECOVERY_FALLBACK] Teleport hacia arriba", Color3.new(1, 0.5, 0))
    end
end

function FSM:StopSafely()
    if self.DeadLatch or self.Phase == "DEAD" then
        Logger:Log("[STOP_BLOCKED] DEAD terminal hasta respawn estable", Color3.new(1, 0.3, 0.3))
        return
    end

    local char, hrp, hum = self:GetValidEntity()
    if hrp then
        if hrp.Position.Y <= (Config.Y_Transito + 1.0) then
            Logger:Log("[STOP] Subterráneo detectado. Rescatando...", Color3.new(1, 0.5, 0))
            self:RecoverToSafeHome(hrp, char)
        else
            Motor:SealCharacter(hrp)
        end
    end
    self:TransitionTo("IDLE", "Manual Stop")
    if hum and hum.Health >= Config.MinStartHealth then
        local released = self:ReleaseCharacterIfSafe("Manual Stop")
        if not released then
            self:RequestSafeRelease("Manual Stop Deferred")
        end
    else
        self:RequestSafeRelease("Manual Stop Low HP")
        Logger:Log("[STOP_SEALED_LOW_HP]", Color3.new(1, 0.5, 0))
    end
end

function FSM:TransitionTo(newPhase, reason, extraCFrame)
    if self.Phase == newPhase then return end

    if self.Phase == "DEAD" and newPhase ~= "DEAD" and reason ~= "CharacterAdded Stable" and reason ~= "Cleanup" then
        Logger:Log("[FSM_BLOCKED] DEAD terminal -> " .. newPhase, Color3.new(1, 0.3, 0.3))
        return
    end

    Logger:Log(string.format("[FSM] %s -> %s (%s)", self.Phase, newPhase, reason or "Auto"), Color3.fromRGB(150, 150, 250))
    
    self.Phase = newPhase
    self.StateID = self.StateID + 1 
    self.LastStabilityPos = nil
    
    if newPhase == "IDLE" or newPhase == "EMERGENCY" or newPhase == "DEAD" then
        Motor:SetGhostMode(false)
    end
    
    if newPhase == "IDLE" then 
        self:ClearTargets()
        self.EmergencyTicks = 0
        if not Config.Activo and not self.DeadLatch then
            self:RequestSafeRelease(reason or "IDLE")
        end
    elseif newPhase == "FLASH_EXIT" then
        local char, hrp = self:GetValidEntity()
        if hrp and extraCFrame then
            Motor:TeleportCharacter(char, hrp, extraCFrame, true)
        end
    elseif newPhase == "EMERGENCY" then
        self:ClearTargets()
        self.EmergencyTicks = 0
        self.LastEmergencyAt = tick()
        local char, hrp = self:GetValidEntity()
        if hrp then
            self:RecoverToSafeHome(hrp, char)
            Logger:Log("[TELEMETRY] EMERGENCY Latch Activo", Color3.new(1, 0, 0))
        end
    elseif newPhase == "RETURN" then
        self:ClearTargets()
    elseif newPhase == "DEAD" then
        self:ClearTargets()
        self.DeadLatch = true
        self.EmergencyTicks = 0
    end 
end

-- ==============================================================================
-- 5. LÓGICA DE VIAJE Y BURST
-- ==============================================================================
function Motor:Travel(targetCF, expectedToken)
    local char, hrp = FSM:GetValidEntity()
    if not hrp then return false, "NO_ENTITY" end

    Motor:SealCharacter(hrp)
    
    local startCF = hrp.CFrame 
    local dist = (Vector2.new(startCF.X, startCF.Z) - Vector2.new(targetCF.X, targetCF.Z)).Magnitude 
    local duration = math.max(dist / Config.Velocidad, 0.1) 
    local startTime = tick() 
    local status = "PENDING" 
    
    local conn
    conn = RS.RenderStepped:Connect(function() 
        if not Config.Activo then
            status = "ABORTED_MANUAL"
            return
        end
        if FSM.StateID ~= expectedToken then
            status = "STATE_OVERRIDDEN"
            return
        end
        if not FSM:GetValidEntity() then
            status = "NO_ENTITY"
            return
        end
        local elapsed = tick() - startTime 
        local alpha = math.clamp(elapsed / duration, 0, 1) 
        hrp.CFrame = startCF:Lerp(targetCF, alpha) 
        Motor:StopMotion(hrp)
        if alpha >= 1 then status = "OK" end 
    end) 
    
    local timeout = duration + 2
    while status == "PENDING" and (tick() - startTime) < timeout do RS.Heartbeat:Wait() end 
    if conn then conn:Disconnect() end 
    if status == "PENDING" then status = "TIMEOUT" end
    
    return status == "OK", status 
end

function Motor:ExecuteBurst(targetRoot, prompt, cCobro, burstToken)
    local char, hrp = FSM:GetValidEntity()
    if not hrp then return false, "NO_ENTITY" end
    if not prompt or not prompt:IsDescendantOf(workspace) then return false, "NO_PROMPT" end

    local tempConnections = {}
    local triggeredObserved = false
    local promptHiddenObserved = false
    local postTriggerReleaseActive = false
    local postTriggerReleaseUntil = 0
    local postTriggerResealLogged = false
    local targetContainer = targetRoot and targetRoot.Parent or nil
    local activeBrainrots = workspace:FindFirstChild("ActiveBrainrots")
    local toolSnapshotBefore = GetOwnedToolCounts()
    local characterChildrenBefore = GetChildSignatureCounts(char)
    local characterDescendantsBefore = GetRelevantDescendantSignatureCounts(char)
    local burstSignals = {
        claimSeen = false,
        claimReason = nil,
        charAdded = {},
        charRemoved = {},
        descAdded = {},
        descRemoved = {},
        toolAdded = {},
        toolRemoved = {},
    }
    local promptPropsBefore = {
        RequiresLineOfSight = prompt.RequiresLineOfSight,
        MaxActivationDistance = prompt.MaxActivationDistance,
        HoldDuration = prompt.HoldDuration,
    }

    local function noteSignal(bucket, instance)
        if not bucket or not instance then return end
        local key = string.format("%s|%s", instance.ClassName, instance.Name)
        bucket[key] = (bucket[key] or 0) + 1
    end

    local function isRelevantCarryEvent(instance)
        if not instance then return false end
        if IsCarryRelevantDescendant(instance) then
            return true
        end

        local loweredName = string.lower(instance.Name)
        return loweredName == "takeprompt" or loweredName == "renderedbrainrot"
    end

    local function restorePromptProps()
        if not prompt or not prompt:IsDescendantOf(workspace) then return end
        pcall(function()
            prompt.RequiresLineOfSight = promptPropsBefore.RequiresLineOfSight
            prompt.MaxActivationDistance = promptPropsBefore.MaxActivationDistance
            prompt.HoldDuration = promptPropsBefore.HoldDuration
        end)
    end

    local function enablePostTriggerRelease(reason)
        if not Config.BurstPostTriggerRelease then return end
        postTriggerReleaseActive = true
        postTriggerReleaseUntil = math.max(postTriggerReleaseUntil, tick() + Config.BurstPostTriggerGrace)
        postTriggerResealLogged = false
        Logger:Log("[TELEMETRY] POST_TRIGGER_RELEASE: " .. tostring(reason), Color3.new(0, 1, 1))
    end

    local function disconnectTempConnections()
        for _, conn in ipairs(tempConnections) do
            pcall(function() conn:Disconnect() end)
        end
        table.clear(tempConnections)
    end

    local function getEntityLossReason()
        local liveChar = player.Character
        if not liveChar then
            return "CHAR_NIL"
        end

        local liveRoot = liveChar:FindFirstChild("HumanoidRootPart")
        if not liveRoot then
            return "HRP_NIL"
        end

        local liveHum = liveChar:FindFirstChildOfClass("Humanoid")
        if not liveHum then
            return "HUM_NIL"
        end

        if liveHum.Health <= 0 then
            return "HUM_DEAD"
        end

        return string.format("UNSPECIFIED hp=%.1f anchored=%s y=%.2f", liveHum.Health, tostring(liveRoot.Anchored), liveRoot.Position.Y)
    end

    local function getCarryConfirmation()
        local toolSnapshotNow = GetOwnedToolCounts()
        local equippedDelta, equippedNames = GetPositiveToolDelta(toolSnapshotBefore.characterByName, toolSnapshotNow.characterByName)
        if equippedDelta > 0 then
            return true, "TOOL_EQUIPPED_OK: " .. tostring(equippedNames ~= "" and equippedNames or equippedDelta)
        end

        local totalDelta, totalNames = GetPositiveToolDelta(toolSnapshotBefore.totalByName, toolSnapshotNow.totalByName)
        if totalDelta > 0 then
            return true, "TOOL_DELTA_OK: " .. tostring(totalNames ~= "" and totalNames or totalDelta)
        end

        return false, nil
    end

    local function getDirectCarryStateConfirmation()
        local liveChar = player.Character
        if not liveChar then return false, nil end

        local liveRoot = liveChar:FindFirstChild("HumanoidRootPart")
        if liveRoot then
            local holdWeld = liveRoot:FindFirstChild("HoldWeld")
            if holdWeld and holdWeld:IsA("Weld") then
                return true, "HOLD_WELD_OK"
            end
        end

        local rendered = liveChar:FindFirstChild("RenderedBrainrot")
        if rendered and rendered:IsA("Model") then
            return true, "CHAR_RENDERED_OK"
        end

        if targetRoot and targetRoot:IsDescendantOf(liveChar) then
            return true, "TARGET_ON_CHAR_OK"
        end

        if prompt and prompt:IsDescendantOf(liveChar) then
            return true, "PROMPT_ON_CHAR_OK"
        end

        return false, nil
    end

    local function getTransientCarryConfirmation()
        local toolEventText = FormatSignalCounts(burstSignals.toolAdded, 4)
        if toolEventText ~= "" then
            return true, "TOOL_EVENT_OK: " .. toolEventText
        end

        local descEventText = FormatSignalCounts(burstSignals.descAdded, 5)
        if descEventText ~= "" then
            return true, "CHAR_DESC_EVENT_OK: " .. descEventText
        end

        local childEventText = FormatSignalCounts(burstSignals.charAdded, 5)
        if childEventText ~= "" then
            return true, "CHAR_ATTACH_EVENT_OK: " .. childEventText
        end

        if promptHiddenObserved and burstSignals.claimSeen then
            local removedDescText = FormatSignalCounts(burstSignals.descRemoved, 5)
            if removedDescText ~= "" then
                return true, "PROMPT_HIDDEN_DESC_OK: " .. removedDescText
            end

            local removedChildText = FormatSignalCounts(burstSignals.charRemoved, 5)
            if removedChildText ~= "" then
                return true, "PROMPT_HIDDEN_ATTACH_OK: " .. removedChildText
            end
        end

        return false, nil
    end

    local function getCharacterAttachConfirmation()
        local liveChar = player.Character
        local directOk, directReason = getDirectCarryStateConfirmation()
        if directOk then
            return true, directReason
        end

        local hasDescDelta, descDeltaNames = GetSignatureDelta(characterDescendantsBefore, GetRelevantDescendantSignatureCounts(liveChar))
        if hasDescDelta then
            return true, "CHAR_DESC_OK: " .. tostring(descDeltaNames)
        end

        local hasDelta, deltaNames = GetSignatureDelta(characterChildrenBefore, GetChildSignatureCounts(liveChar))
        if hasDelta then
            return true, "CHAR_ATTACH_OK: " .. tostring(deltaNames)
        end
        return false, nil
    end

    local function getWorldClaimConfirmation()
        local activeFolder = workspace:FindFirstChild("ActiveBrainrots") or activeBrainrots
        if targetRoot and activeFolder and not targetRoot:IsDescendantOf(activeFolder) then
            burstSignals.claimSeen = true
            burstSignals.claimReason = "CLAIM_WORLD_OK: target salio de ActiveBrainrots"
            enablePostTriggerRelease(burstSignals.claimReason)
            return true, "CLAIM_WORLD_OK: target salio de ActiveBrainrots"
        end
        if targetRoot and not targetRoot:IsDescendantOf(workspace) then
            burstSignals.claimSeen = true
            burstSignals.claimReason = "TARGET_REMOVED_OK: target removido de workspace"
            enablePostTriggerRelease(burstSignals.claimReason)
            return true, "TARGET_REMOVED_OK: target removido de workspace"
        end
        if prompt then
            if not prompt:IsDescendantOf(workspace) then
                burstSignals.claimSeen = true
                burstSignals.claimReason = "PROMPT_MISSING_OK: prompt removido de workspace"
                enablePostTriggerRelease(burstSignals.claimReason)
                return true, "PROMPT_MISSING_OK: prompt removido de workspace"
            end
            if targetContainer and not prompt:IsDescendantOf(targetContainer) then
                burstSignals.claimSeen = true
                burstSignals.claimReason = "PROMPT_REPARENT_OK: prompt movido fuera del target"
                enablePostTriggerRelease(burstSignals.claimReason)
                return true, "PROMPT_REPARENT_OK: prompt movido fuera del target"
            end
            if activeFolder and not prompt:IsDescendantOf(activeFolder) then
                burstSignals.claimSeen = true
                burstSignals.claimReason = "PROMPT_FOLDER_EXIT_OK: prompt salio de ActiveBrainrots"
                enablePostTriggerRelease(burstSignals.claimReason)
                return true, "PROMPT_FOLDER_EXIT_OK: prompt salio de ActiveBrainrots"
            end
        end
        return false, nil
    end

    local function finishBurst(ok, reason)
        local _, finishRoot = FSM:GetValidEntity()
        if finishRoot then
            Motor:SealCharacter(finishRoot)
        end
        restorePromptProps()
        disconnectTempConnections()
        return ok, reason
    end

    local function maintainBurstPose(liveChar, liveRoot, allowFree)
        if not liveChar or not liveRoot then return end

        if allowFree and postTriggerReleaseActive then
            if tick() <= postTriggerReleaseUntil then
                if liveRoot.Anchored then
                    Motor:ReleaseCharacter(liveRoot)
                end
                return
            end

            if not postTriggerResealLogged then
                postTriggerResealLogged = true
                Logger:Log("[TELEMETRY] POST_TRIGGER_RESEAL", Color3.new(1, 1, 0))
            end
        end

        Motor:SealCharacter(liveRoot)
        liveChar:PivotTo(cCobro)
        Motor:StopMotion(liveRoot)
    end

    local function waitForClaimSettle(claimReason)
        Logger:Log("[TELEMETRY] CLAIM_SEEN_SETTLING: " .. tostring(claimReason), Color3.new(0, 1, 1))
        local deadline = tick() + Config.BurstClaimSettleWindow

        while tick() < deadline do
            if not Config.Activo then return false, "BURST_ABORT_MANUAL" end
            if FSM.StateID ~= burstToken then return false, "STATE_OVERRIDDEN" end

            local charS, hrpS, humS = FSM:GetValidEntity()
            if not hrpS or not charS or not humS then
                Logger:Log("[TELEMETRY] ENTITY_LOST_SETTLE: " .. getEntityLossReason(), Color3.new(1, 0, 0))
                return false, "NO_ENTITY"
            end

            local lastHP = humS:GetAttribute("LastHP") or humS.Health
            if humS.Health < lastHP then return false, "HP_DROPPED_IN_BURST" end

            maintainBurstPose(charS, hrpS, true)

            local carryConfirmed, carryReason = getCarryConfirmation()
            if carryConfirmed then
                Logger:Log("[TELEMETRY] PICKUP_CONFIRMED: " .. tostring(carryReason), Color3.new(0, 1, 0))
                return true, carryReason
            end

            local attachConfirmed, attachReason = getCharacterAttachConfirmation()
            if attachConfirmed then
                Logger:Log("[TELEMETRY] PICKUP_CONFIRMED: " .. tostring(attachReason), Color3.new(0, 1, 0))
                return true, attachReason
            end

            local transientConfirmed, transientReason = getTransientCarryConfirmation()
            if transientConfirmed then
                Logger:Log("[TELEMETRY] PICKUP_CONFIRMED: " .. tostring(transientReason), Color3.new(0, 1, 0))
                return true, transientReason
            end

            local claimedStillThere, _ = getWorldClaimConfirmation()
            if not claimedStillThere then
                Logger:Log("[TELEMETRY] CLAIM_SETTLE_LOST", Color3.new(1, 0.5, 0))
                return false, "CLAIM_SETTLE_LOST"
            end

            RS.Heartbeat:Wait()
        end

        Logger:Log("[TELEMETRY] CLAIM_SETTLE_NO_ATTACH", Color3.new(1, 0.5, 0))
        return false, "CLAIM_WITHOUT_CARRY_CONFIRM"
    end

    if prompt then
        table.insert(tempConnections, prompt.PromptHidden:Connect(function()
            promptHiddenObserved = true
            Logger:Log("[TELEMETRY] PROMPT_HIDDEN", Color3.new(1, 1, 0))
        end))
        table.insert(tempConnections, prompt.PromptButtonHoldBegan:Connect(function(playerWhoTriggered)
            if playerWhoTriggered == player then
                Logger:Log("[TELEMETRY] PROMPT_HOLD_BEGAN", Color3.new(1, 1, 0))
            end
        end))
        table.insert(tempConnections, prompt.PromptButtonHoldEnded:Connect(function(playerWhoTriggered)
            if playerWhoTriggered == player then
                Logger:Log("[TELEMETRY] PROMPT_HOLD_ENDED", Color3.new(1, 0.7, 0))
            end
        end))
        table.insert(tempConnections, prompt.Triggered:Connect(function(playerWhoTriggered)
            if playerWhoTriggered == player then
                triggeredObserved = true
                enablePostTriggerRelease("PROMPT_TRIGGERED")
                Logger:Log("[TELEMETRY] PROMPT_TRIGGERED", Color3.new(0, 1, 0))
            end
        end))
        table.insert(tempConnections, prompt.TriggerEnded:Connect(function(playerWhoTriggered)
            if playerWhoTriggered == player then
                Logger:Log("[TELEMETRY] PROMPT_TRIGGER_ENDED", Color3.new(0.7, 1, 0.2))
            end
        end))
    end

    if char then
        table.insert(tempConnections, char.ChildAdded:Connect(function(child)
            if isRelevantCarryEvent(child) then
                noteSignal(burstSignals.charAdded, child)
            end
        end))
        table.insert(tempConnections, char.ChildRemoved:Connect(function(child)
            if isRelevantCarryEvent(child) then
                noteSignal(burstSignals.charRemoved, child)
            end
        end))
        table.insert(tempConnections, char.DescendantAdded:Connect(function(descendant)
            if isRelevantCarryEvent(descendant) then
                noteSignal(burstSignals.descAdded, descendant)
            end
        end))
        table.insert(tempConnections, char.DescendantRemoving:Connect(function(descendant)
            if isRelevantCarryEvent(descendant) then
                noteSignal(burstSignals.descRemoved, descendant)
            end
        end))
    end

    local backpack = player:FindFirstChildOfClass("Backpack")
    if backpack then
        table.insert(tempConnections, backpack.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                noteSignal(burstSignals.toolAdded, child)
            end
        end))
        table.insert(tempConnections, backpack.ChildRemoved:Connect(function(child)
            if child:IsA("Tool") then
                noteSignal(burstSignals.toolRemoved, child)
            end
        end))
    end

    Motor:SealCharacter(hrp)
    Motor:TeleportCharacter(char, hrp, cCobro, true)
    Logger:Log("[TELEMETRY] PRE_BURST", Color3.new(1, 1, 0))
    
    Motor:SealCharacter(hrp)
    Motor:TeleportCharacter(char, hrp, cCobro, true)
    Logger:Log("[TELEMETRY] POST_PROBE", Color3.new(1, 1, 0))
    if Config.BurstProbeFree then
        Motor:ReleaseCharacter(hrp)
        RS.Heartbeat:Wait()
        Motor:SealCharacter(hrp)
        Motor:TeleportCharacter(char, hrp, cCobro, true)
        Logger:Log("[TELEMETRY] PROBE_FREE", Color3.new(1, 1, 0))
    end
    
    -- [EXPLICACIÓN DEL FALLO LÓGICO DE BURST ANTERIOR]
    -- El burst disparaba sin comprobar si estábamos dentro de MaxActivationDistance 3D.
    -- Con esta telemetría pura sabrás exactamente por qué falla.
    pcall(function()
        prompt.RequiresLineOfSight = false
        prompt.MaxActivationDistance = Config.BurstPromptMaxDistance
    end)

    local maxDist = prompt and prompt.MaxActivationDistance or 0
    local hDur = prompt and prompt.HoldDuration or 0
    local pPos = GetPromptWorldPosition(prompt, targetRoot.Position)
    local burstY = cCobro.Position.Y
    local d3D = (hrp.Position - pPos).Magnitude
    local dXZ = math.sqrt((hrp.Position.X - pPos.X)^2 + (hrp.Position.Z - pPos.Z)^2)

    Logger:Log(string.format("[BURST_INFO] 3D:%.1f|XZ:%.1f|Y:%.1f|PromptY:%.1f|BurstY:%.1f", d3D, dXZ, hrp.Position.Y, pPos.Y, burstY), Color3.new(0, 1, 1))
    Logger:Log(string.format("[BURST_INFO] Hold:%.1fs|MaxD:%.1f|Anc:%s", hDur, maxDist, tostring(hrp.Anchored)), Color3.new(0, 1, 1))
    Logger:Log("[BURST_MODE] POST_TRIGGER_RELEASE", Color3.new(0, 1, 1))

    task.wait(Config.BurstPromptSetupDelay)

    local function checkPositiveConfirmation(logPrefix)
        local carryConfirmed, carryReason = getCarryConfirmation()
        if carryConfirmed then
            Logger:Log("[TELEMETRY] " .. tostring(carryReason), Color3.new(0, 1, 0))
            return true, carryReason
        end

        local attachConfirmed, attachReason = getCharacterAttachConfirmation()
        if attachConfirmed then
            Logger:Log("[TELEMETRY] " .. tostring(attachReason), Color3.new(0, 1, 0))
            return true, attachReason
        end

        local transientConfirmed, transientReason = getTransientCarryConfirmation()
        if transientConfirmed then
            Logger:Log("[TELEMETRY] " .. tostring(transientReason), Color3.new(0, 1, 0))
            return true, transientReason
        end

        local claimed, claimedReason = getWorldClaimConfirmation()
        if claimed then
            Logger:Log("[TELEMETRY] " .. tostring(logPrefix) .. ": " .. tostring(claimedReason), Color3.new(0, 1, 1))
            return waitForClaimSettle(claimedReason)
        end

        return false, nil
    end

    local function performPromptInteraction(livePrompt)
        if not livePrompt then return false, "NO_PROMPT" end

        local holdDuration = livePrompt.HoldDuration or 0
        if holdDuration > 0 then
            local ok, err = pcall(function()
                livePrompt:InputHoldBegin()
                task.wait(holdDuration + Config.BurstHoldExtra)
                livePrompt:InputHoldEnd()
            end)
            return ok, ok and "INPUT_HOLD" or err
        end

        if fireproximityprompt then
            local ok, err = pcall(function()
                fireproximityprompt(livePrompt)
            end)
            return ok, ok and "FIRE_PROMPT" or err
        end

        return false, "NO_INTERACT_IMPL"
    end

    local totalAttempts = ((prompt.HoldDuration or 0) > 0) and Config.BurstHoldAttempts or Config.BurstRapidAttempts

    for attempt = 1, totalAttempts do
        if not Config.Activo then return finishBurst(false, "BURST_ABORT_MANUAL") end
        if FSM.StateID ~= burstToken then return finishBurst(false, "STATE_OVERRIDDEN") end

        local charB, hrpB, humB = FSM:GetValidEntity()
        if not hrpB or not charB or not humB then
            Logger:Log("[TELEMETRY] ENTITY_LOST_PRE_FIRE: " .. getEntityLossReason(), Color3.new(1, 0, 0))
            return finishBurst(false, "NO_ENTITY")
        end

        local lastHP = humB:GetAttribute("LastHP") or humB.Health
        if humB.Health < lastHP then return finishBurst(false, "HP_DROPPED_IN_BURST") end

        maintainBurstPose(charB, hrpB, false)

        local earlyOk, earlyReason = checkPositiveConfirmation("CLAIM_PRE_FIRE")
        if earlyOk then
            Logger:Log("[TELEMETRY] PICKUP_CONFIRMED: " .. tostring(earlyReason), Color3.new(0, 1, 0))
            return finishBurst(true, earlyReason)
        elseif earlyReason == "CLAIM_WITHOUT_CARRY_CONFIRM" or earlyReason == "CLAIM_SETTLE_LOST" then
            return finishBurst(false, earlyReason)
        end

        if not targetRoot or not targetRoot:IsDescendantOf(workspace) then
            Logger:Log("[TELEMETRY] TARGET_VANISHED_PRE_CONFIRM", Color3.new(1, 0.5, 0))
            return finishBurst(false, "TARGET_VANISHED_PRE_CONFIRM")
        end

        if not prompt or not prompt:IsDescendantOf(workspace) or not prompt.Enabled then
            Logger:Log("[TELEMETRY] NO_PROMPT_PRE_FIRE", Color3.new(1, 0.5, 0))
            return finishBurst(false, "NO_PROMPT")
        end

        maintainBurstPose(charB, hrpB, true)

        local fireOk, fireErr = performPromptInteraction(prompt)

        if fireOk then
            Logger:Log("[TELEMETRY] GRAB_FIRE attempt=" .. tostring(attempt) .. " mode=" .. tostring(fireErr), Color3.new(1, 1, 0))
        elseif attempt == 1 or fireErr then
            Logger:Log("[TELEMETRY] GRAB_FIRE_FAIL attempt=" .. tostring(attempt) .. " err=" .. tostring(fireErr), Color3.new(1, 0.5, 0))
        end

        local postOk, postReason = checkPositiveConfirmation("CLAIM_POST_FIRE")
        if postOk then
            Logger:Log("[TELEMETRY] PICKUP_CONFIRMED: " .. tostring(postReason), Color3.new(0, 1, 0))
            return finishBurst(true, postReason)
        elseif postReason == "CLAIM_WITHOUT_CARRY_CONFIRM" or postReason == "CLAIM_SETTLE_LOST" then
            return finishBurst(false, postReason)
        end

        if triggeredObserved or promptHiddenObserved or burstSignals.claimSeen then
            Logger:Log("[TELEMETRY] TRIGGER_SEEN_WAIT_SETTLE", Color3.new(1, 1, 0))
            break
        end

        task.wait(Config.BurstRapidAttemptDelay)
    end

    local confirmDeadline = tick() + Config.BurstPostFireConfirmWindow
    while tick() < confirmDeadline do
        if not Config.Activo then return finishBurst(false, "BURST_ABORT_MANUAL") end
        if FSM.StateID ~= burstToken then return finishBurst(false, "STATE_OVERRIDDEN") end

        local charB, hrpB, humB = FSM:GetValidEntity()
        if not hrpB or not charB or not humB then
            Logger:Log("[TELEMETRY] ENTITY_LOST_CONFIRM: " .. getEntityLossReason(), Color3.new(1, 0, 0))
            return finishBurst(false, "NO_ENTITY")
        end

        local lastHP = humB:GetAttribute("LastHP") or humB.Health
        if humB.Health < lastHP then return finishBurst(false, "HP_DROPPED_IN_BURST") end

        maintainBurstPose(charB, hrpB, true)

        local confirmOk, confirmReason = checkPositiveConfirmation("CONFIRM_WINDOW")
        if confirmOk then
            Logger:Log("[TELEMETRY] PICKUP_CONFIRMED: " .. tostring(confirmReason), Color3.new(0, 1, 0))
            return finishBurst(true, confirmReason)
        elseif confirmReason == "CLAIM_WITHOUT_CARRY_CONFIRM" or confirmReason == "CLAIM_SETTLE_LOST" then
            return finishBurst(false, confirmReason)
        end

        if targetRoot and not targetRoot:IsDescendantOf(workspace) then
            Logger:Log("[TELEMETRY] TARGET_VANISHED_PRE_CONFIRM", Color3.new(1, 0.5, 0))
            return finishBurst(false, "TARGET_VANISHED_PRE_CONFIRM")
        end

        if not prompt or not prompt:IsDescendantOf(workspace) then
            Logger:Log("[TELEMETRY] NO_PROMPT_CONFIRM", Color3.new(1, 0.5, 0))
            return finishBurst(false, "NO_PROMPT")
        end

        RS.Heartbeat:Wait()
    end

    Logger:Log("[TELEMETRY] GRAB_FAIL_NO_CONFIRM", Color3.new(1, 0.5, 0))
    if triggeredObserved then
        Logger:Log("[TELEMETRY] TRIGGER_WITHOUT_PICKUP_CONFIRM", Color3.new(1, 0.5, 0))
        return finishBurst(false, "TRIGGER_WITHOUT_PICKUP_CONFIRM")
    end
    return finishBurst(false, "PROMPT_NOT_CONFIRMED")
end

-- ==============================================================================
-- 6. SECUENCIA NÚCLEO (L-SHAPE ROUTING)
-- ==============================================================================
local function FarmRoutine(targetRoot, prompt)
    if FSM.Phase ~= "IDLE" then return end
    if not targetRoot or not targetRoot:IsDescendantOf(workspace) or not prompt or not prompt:IsDescendantOf(workspace) or not prompt.Enabled then return end
    
    local char, hrp = FSM:GetValidEntity()
    if not hrp or not Config.Home then return end
    if FSM:IsTargetCoolingDown(targetRoot, prompt) then return end

    local blocked, reason = FSM:IsRoutineBlocked()
    if blocked then
        if (tick() - (FSM.LastStartBlockLogAt or 0)) > 1.0 then
            Logger:Log("[START_BLOCKED] " .. tostring(reason), Color3.new(1, 0.5, 0))
            FSM.LastStartBlockLogAt = tick()
        end
        return
    end

    FSM.TargetRoot = targetRoot 
    FSM.TargetPrompt = prompt 
    Motor:SetGhostMode(true) 
    
    local diff = (hrp.Position - targetRoot.Position) 
    local dirXZ = Vector3.new(diff.X, 0, diff.Z) 
    dirXZ = dirXZ.Magnitude < 0.01 and Vector3.new(1,0,0) or dirXZ.Unit 
    local spotXZ = targetRoot.Position + (dirXZ * Config.Distancia) 
    local promptPos = GetPromptWorldPosition(prompt, targetRoot.Position)
    
    local posHRP = hrp.Position 
    local cDropLocal = CFrame.lookAt(Vector3.new(posHRP.X, Config.Y_Transito, posHRP.Z), Vector3.new(spotXZ.X, Config.Y_Transito, spotXZ.Z)) 
    local cTrans = CFrame.lookAt(Vector3.new(spotXZ.X, Config.Y_Transito, spotXZ.Z), Vector3.new(targetRoot.Position.X, Config.Y_Transito, targetRoot.Position.Z)) 
    local burstY = promptPos.Y + Config.BurstPromptRootOffset
    local burstPos = Vector3.new(promptPos.X, burstY, promptPos.Z)
    local burstLook = Vector3.new(targetRoot.Position.X, burstY, targetRoot.Position.Z)
    if (burstLook - burstPos).Magnitude < 0.01 then
        burstLook = burstPos + Vector3.new(1, 0, 0)
    end
    local cCobro = CFrame.lookAt(burstPos, burstLook) 
    
    FSM:TransitionTo("TRANSIT_DROP", "Bajar")
    local okD, errD = Motor:Travel(cDropLocal, FSM.StateID) 
    if not okD then if FSM.Phase == "TRANSIT_DROP" then FSM:TransitionTo("EMERGENCY", errD) end; return end 
    
    FSM:TransitionTo("TRANSIT_HORIZONTAL", "Acercar")
    local okT, errT = Motor:Travel(cTrans, FSM.StateID) 
    if not okT then if FSM.Phase == "TRANSIT_HORIZONTAL" then FSM:TransitionTo("EMERGENCY", errT) end; return end 
    
    FSM:TransitionTo("BURST", "Interact") 
    local okB, errB = Motor:ExecuteBurst(targetRoot, prompt, cCobro, FSM.StateID) 
    if not okB then 
        if FSM.Phase == "BURST" then
            if errB == "NO_PROMPT" or errB == "PROMPT_NOT_CONFIRMED" or errB == "TRIGGER_WITHOUT_PICKUP_CONFIRM" or errB == "CLAIM_WITHOUT_CARRY_CONFIRM" or errB == "CLAIM_SETTLE_LOST" or errB == "TARGET_VANISHED_PRE_CONFIRM" then
                FSM:MarkTargetCooldown(targetRoot, prompt, Config.TargetRetryCooldown, errB)
                local recoverChar, recoverRoot = FSM:GetValidEntity()
                if recoverRoot then
                    FSM:RecoverToSafeHome(recoverRoot, recoverChar)
                end
                Logger:Log("[BURST_SOFT_RESET] " .. tostring(errB), Color3.new(1, 0.6, 0))
                FSM:TransitionTo("IDLE", "Burst Soft Reset")
            else
                FSM:TransitionTo("EMERGENCY", errB)
            end
        end 
        return
    end 

    FSM:TransitionTo("RETURN", "Safe Extract")
    local charAfter, hrpAfter = FSM:GetValidEntity()
    if not hrpAfter then
        if FSM.Phase == "RETURN" then FSM:TransitionTo("EMERGENCY", "POST_BURST_NO_ENTITY") end
        return
    end
    if not FSM:IsHomeCFrameSafe(Config.Home) then
        if FSM.Phase == "RETURN" then FSM:TransitionTo("EMERGENCY", "HOME_INVALID") end
        return
    end
    Motor:TeleportCharacter(charAfter, hrpAfter, Config.Home + Vector3.new(0, 3, 0), true)
    Logger:Log("[RETURN_MODE] SAFE_HOME_TP", Color3.new(0, 1, 1))
    FSM:MarkTargetCooldown(targetRoot, prompt, Config.TargetSuccessCooldown, "SUCCESS_SETTLE")
    
    FSM:TransitionTo("IDLE", "Farm Success")
    local _, safeRoot = FSM:GetValidEntity()
    if safeRoot then
        Motor:SealCharacter(safeRoot)
    end
    if not Config.Activo then
        FSM:ReleaseCharacterIfSafe("Farm Success")
    else
        Logger:Log("[CYCLE_READY_SEALED]", Color3.new(0, 1, 0))
    end
end

-- ==============================================================================
-- 7. EVENTOS Y CONTROL DE FLUJO
-- ==============================================================================
table.insert(Threads, task.spawn(function()
    while RS.Heartbeat:Wait() do
        local char, hrp, hum = FSM:GetValidEntity()
        if hrp and hum then
            if not Config.Activo and FSM.Phase == "IDLE" and FSM.PendingSafeRelease and not FSM.DeadLatch then
                local now = tick()
                if (now - (FSM.LastReleaseAttemptAt or 0)) >= Config.AutoReleaseRetryEvery then
                    FSM.LastReleaseAttemptAt = now
                    local released = FSM:ReleaseCharacterIfSafe(FSM.PendingSafeReleaseReason or "Deferred Release")
                    if not released then
                        Motor:SealCharacter(hrp)
                    end
                end
            end

            if Config.Activo then
                if FSM.Phase == "EMERGENCY" then
                    Motor:SealCharacter(hrp)
                    if FSM:IsHomeCFrameSafe(Config.Home) then
                        if hrp.Position.Y < (Config.Y_Transito + 0.5) then
                            Motor:TeleportCharacter(char, hrp, Config.Home + Vector3.new(0, 3, 0), true)
                            FSM.EmergencyTicks = 0
                        else
                            local stable, reason, nextPos = FSM:CheckStabilitySample(hrp, hum, FSM.LastStabilityPos, {
                                minY = Config.Y_Transito + 1.0,
                                minHealth = Config.MinRecoverHealth,
                                requireAnchored = true
                            })
                            FSM.LastStabilityPos = nextPos
                            FSM.EmergencyTicks = stable and ((FSM.EmergencyTicks or 0) + 1) or 0
                            if FSM.EmergencyTicks > Config.ReleaseStableFrames then
                                Logger:Log("[RECOVERY] Saliendo de EMERGENCY con ventana estable", Color3.new(0, 1, 0))
                                FSM:TransitionTo("IDLE", "Auto Recovery Stable")
                            elseif not stable and reason == "LOW_HP" then
                                if ((FSM.LastStartBlockLogAt or 0) + 1.0) < tick() then
                                    Logger:Log("[RECOVERY_BLOCKED] LOW_HP_RECOVER", Color3.new(1, 0.5, 0))
                                    FSM.LastStartBlockLogAt = tick()
                                end
                            end
                        end
                    else
                        FSM.EmergencyTicks = 0
                    end
                end

                local distXZ = -1
                local dist3D = -1
                if FSM.TargetRoot and FSM.TargetRoot.Parent then 
                    local pPos = FSM.TargetRoot.Position
                    dist3D = (hrp.Position - pPos).Magnitude
                    distXZ = math.sqrt((hrp.Position.X - pPos.X)^2 + (hrp.Position.Z - pPos.Z)^2)
                end
                
                Logger.Snapshots[Logger.SnapIndex] = { 
                    t = tick(), hp = hum.Health, y = hrp.Position.Y, vy = hrp.AssemblyLinearVelocity.Y, 
                    phase = FSM.Phase, distXZ = distXZ, dist3D = dist3D, anchored = hrp.Anchored 
                }
                Logger.SnapIndex = (Logger.SnapIndex % 30) + 1
                
                local currentHP = hum.Health 
                local lastHP = hum:GetAttribute("LastHP") or currentHP 
                if currentHP < lastHP and FSM.Phase ~= "IDLE" and FSM.Phase ~= "EMERGENCY" then 
                    Logger:Log("[TELEMETRY] HP_CHANGE: " .. tostring(lastHP) .. " -> " .. tostring(currentHP), Color3.new(1, 0, 0))
                    if currentHP <= Config.MinRecoverHealth then
                        Logger:Dump("CRITICAL_DAMAGE") 
                        FSM:TransitionTo("EMERGENCY", "Critical Damage Abort") 
                    end
                end 
                hum:SetAttribute("LastHP", currentHP) 

                if hrp.AssemblyLinearVelocity.Y < -40.0 and FSM.Phase ~= "IDLE" and FSM.Phase ~= "EMERGENCY" and FSM.Phase ~= "DEAD" then
                    Logger:Dump("FALLING_DETECTED")
                    FSM:TransitionTo("EMERGENCY", "Physics Fall Abort")
                end
            end
        end 
    end 
end))

table.insert(Threads, task.spawn(function()
    while task.wait(0.2) do
        if Config.Activo and FSM.Phase == "IDLE" then
            local char, hrp = FSM:GetValidEntity()
            if hrp then
                local folder = workspace:FindFirstChild("ActiveBrainrots")
                if folder then
                    local bt, bp, md = nil, nil, math.huge
                    for _, r in pairs(folder:GetChildren()) do 
                        for _, rot in pairs(r:GetChildren()) do
                            if rot:GetAttribute("Mutation") == Config.Mutacion then
                                local tr = rot:FindFirstChild("Root"); local pr = rot:FindFirstChild("TakePrompt", true)
                                if tr and pr and pr.Enabled and (not FSM:IsTargetCoolingDown(tr, pr)) then
                                    local dx = hrp.Position.X - tr.Position.X
                                    local dz = hrp.Position.Z - tr.Position.Z
                                    local dXZ = math.sqrt(dx*dx + dz*dz)
                                    if dXZ < md then md = dXZ; bt = tr; bp = pr end
                                end
                            end
                        end 
                    end
                    if bt then FarmRoutine(bt, bp) end
                end
            end
        end
    end
end))

local lastMutsCache = ""
table.insert(Threads, task.spawn(function()
    while task.wait(1.5) do
        if Config.Activo then continue end
        local folder = workspace:FindFirstChild("ActiveBrainrots"); if not folder then continue end
        local currentMuts = {}; 
        for _, r in pairs(folder:GetChildren()) do 
            for _, rot in pairs(r:GetChildren()) do 
                local m = rot:GetAttribute("Mutation"); 
                if m and m ~= "None" then currentMuts[m] = true end 
            end 
        end
        local keys = {}; for k in pairs(currentMuts) do table.insert(keys, k) end; table.sort(keys); 
        local cacheString = table.concat(keys, "|")
        if cacheString == lastMutsCache then continue end; lastMutsCache = cacheString

        for i, m in ipairs(keys) do 
            if not UI.ButtonPool[i] then 
                local b = Instance.new("TextButton", mutScroll); b.Size = UDim2.new(1,-10,0,25); b.TextColor3 = Color3.new(1,1,1) 
                UI.ButtonPool[i] = {btn = b, conn = nil} 
            end 
            local bData = UI.ButtonPool[i] 
            bData.btn.Visible = true; bData.btn.Text = m; bData.btn.BackgroundColor3 = (Config.Mutacion == m) and Color3.fromRGB(0,120,200) or Color3.fromRGB(45,45,45) 
            if bData.conn then bData.conn:Disconnect() end 
            bData.conn = bData.btn.MouseButton1Click:Connect(function() Config.Mutacion = m; lastMutsCache = ""; end) 
        end 
        for i = #keys + 1, #UI.ButtonPool do UI.ButtonPool[i].btn.Visible = false end
    end 
end))

-- ==============================================================================
-- 8. UI DRAG & CONTROLES
-- ==============================================================================
local dragging, dragStart, startPos = false, nil, nil

safeConnect(topBar.InputBegan, function(input) 
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then 
        dragging = true 
        dragStart = input.Position 
        startPos = main.Position 
    end 
end)

safeConnect(UIS.InputChanged, function(input) 
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then 
        local delta = input.Position - dragStart 
        main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y) 
    end 
end)

safeConnect(UIS.InputEnded, function(input) 
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then 
        dragging = false 
    end 
end)

safeConnect(btnCopy.MouseButton1Click, function()
    if setclipboard then 
        local cleanBuffer = {}
        for i = 0, 399 do
            local idx = ((Logger.LogIndex + i - 1) % 400) + 1
            local line = Logger.Buffer[idx]
            if line and line ~= "" then
                table.insert(cleanBuffer, line)
            end
        end
        setclipboard(table.concat(cleanBuffer, "\n")); Logger:Log("LOGS COPIADOS", Color3.new(0,1,0)) 
    end
end)

safeConnect(btnToggle.MouseButton1Click, function()
    UI.Minimized = not UI.Minimized
    local newH = UI.Minimized and 30 or 315
    main.Size = UDim2.new(0, 260, 0, newH)
    btnToggle.Text = UI.Minimized and "+" or "−"
    logBox.Visible = not UI.Minimized
    mutScroll.Visible = not UI.Minimized
    footer.Visible = not UI.Minimized
end)

safeConnect(btnAction.MouseButton1Click, function()
    local char, hrp, hum = FSM:GetValidEntity()

    if not Config.Activo then
        if not Config.Mutacion then return end
        if FSM.DeadLatch or FSM.Phase == "DEAD" then
            Logger:Log("[START_BLOCKED] DEAD terminal. Esperando CharacterAdded estable.", Color3.new(1, 0.3, 0.3))
            return
        end
        if not hrp or not hum then
            Logger:Log("[START_BLOCKED] NO_ENTITY", Color3.new(1, 0.5, 0))
            return
        end
        if hum.Health < Config.MinStartHealth then
            Logger:Log("[START_BLOCKED] LOW_HP_START", Color3.new(1, 0.5, 0))
            return
        end

        Motor:SealCharacter(hrp)
        FSM:SaveHomeIfSafe(hrp)
        if not FSM:IsHomeCFrameSafe(Config.Home) then
            Logger:Log("[START_BLOCKED] HOME_INVALID", Color3.new(1, 0.5, 0))
            return
        end

        Config.Activo = true
        btnAction.Text = "DETENER"
        btnAction.BackgroundColor3 = Color3.fromRGB(200, 0, 0)

        if hrp then
            Motor:SealCharacter(hrp)
        end
        Logger:Log("[START_READY_SEALED]", Color3.new(0, 1, 0))
    else
        Config.Activo = false
        btnAction.Text = "INICIAR"
        btnAction.BackgroundColor3 = Color3.fromRGB(0, 150, 50)
        FSM:StopSafely()
    end
end)

safeConnect(player.CharacterRemoving, function(char)
    Logger:Dump("CHARACTER_REMOVING")
    FSM:TransitionTo("DEAD", "CharRemoving")
    FSM.LastStabilityPos = nil
    FSM.Session += 1; Config.Activo = false
    btnAction.Text = "INICIAR"; btnAction.BackgroundColor3 = Color3.fromRGB(0, 150, 50)
end)

safeConnect(player.CharacterAdded, function(char)
    FSM.LastRespawnAt = tick()
    FSM.LastStabilityPos = nil
    FSM:ClearTargets()
    Logger:Log("[RESPAWN] CharacterAdded detectado", Color3.new(0, 1, 1))

    task.spawn(function()
        task.wait(0.4)
        local respawnStamp = FSM.LastRespawnAt
        local ok, reason = FSM:WaitForStableWindow(Config.RespawnStableFrames, {
            minY = Config.Y_Transito + 1.0,
            minHealth = Config.MinRecoverHealth,
            requireAnchored = false,
            maxFrames = 90
        })
        if FSM.LastRespawnAt ~= respawnStamp then return end

        local _, respawnRoot = FSM:GetValidEntity()
        if ok and respawnRoot then
            Motor:SealCharacter(respawnRoot)
            FSM.DeadLatch = false
            if FSM.Phase == "DEAD" then
                FSM:TransitionTo("IDLE", "CharacterAdded Stable")
            end
            if not Config.Activo then
                FSM:RequestSafeRelease("Respawn Stable")
            end
            Logger:Log("[RESPAWN_READY] Character estable", Color3.new(0, 1, 0))
        else
            Logger:Log("[RESPAWN_UNSTABLE] " .. tostring(reason), Color3.new(1, 0.5, 0))
        end
    end)
end)

_G.IvanFarmer_Cleanup = function()
    Config.Activo = false; FSM.Session += 1
    for _, conn in ipairs(Connections) do pcall(function() conn:Disconnect() end) end
    table.clear(Connections)
    for _, th in ipairs(Threads) do pcall(function() task.cancel(th) end) end
    table.clear(Threads)
    FSM:TransitionTo("IDLE", "Cleanup") 
    if CoreGui:FindFirstChild(scriptName) then CoreGui[scriptName]:Destroy() end
end

Logger:Log("V234 Post Trigger Release Ready.", Color3.new(0, 1, 0.4))
Logger:Log(string.format("[CONFIG] PromptRootOff=%.2f | Dist=%.1f | StartHP=%.0f | RecoverHP=%.0f | Burst=%s | PromptMax=%.0f | Attempts=%d | RetryCD=%.2f", Config.BurstPromptRootOffset, Config.Distancia, Config.MinStartHealth, Config.MinRecoverHealth, Config.BurstMode, Config.BurstPromptMaxDistance, Config.BurstRapidAttempts, Config.TargetRetryCooldown), Color3.new(0, 1, 1))
