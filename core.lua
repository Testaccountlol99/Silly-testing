-- ============================================================
--  AIMBOT  |  Anti-Cheat Testing Tool
--  Modes: Blatant / Legit
-- ============================================================

-- ============================================================
-- [0] LOCALISED MATH  (avoids global table lookup in hot paths)
-- ============================================================
local mclamp  = math.clamp
local mhuge   = math.huge
local mrand   = math.random
local msqrt   = math.sqrt
local mmax    = math.max
local mmin    = math.min
local mlog    = math.log
local mcos    = math.cos
local mfloor  = math.floor
local mabs    = math.abs
local TAU   = math.pi * 2        -- 2π constant reused in Box-Muller
local ZERO3 = Vector3.new(0,0,0) -- shared zero vector (immutable)

-- Drawing / Vector shortcuts (avoid global table lookup in hot paths)
local newV2      = Vector2.new
local newC3      = Color3.new
local newDrawing = Drawing.new

-- ============================================================
-- [1] SERVICES
-- ============================================================
local Players     = game:GetService("Players")
local UIS         = game:GetService("UserInputService")
local RunService  = game:GetService("RunService")
local Workspace   = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Camera      = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- [2] CONFIGURATION
-- ============================================================
local Defaults = {
    Enabled          = false,
    EspEnabled       = false,
    PlayerEspEnabled = true,
    EspTextEnabled   = false,
    EspTeamCheck     = true,
    EspTeamColors    = false,
    EspType          = "Box",
    WallCheck        = true,
    Mode             = "Legit",
    TeamCheck        = true,
    Prediction       = true,
    TargetPart       = "Head",
    -- General
    FOV                = 50,
    MaxDistance        = 100,
    PredictionFactor   = 1.0,
    Smoothness         = 0.4,
    AdaptivePrediction = true,
    -- Health Check
    HealthCheckEnabled = false,
    HealthMinHP        = 0,
    HealthMaxHP        = 100,
    -- Legit
    MinReactionTime  = 0.15,
    MaxReactionTime  = 0.35,
    MeanReactionTime = 0.22,
    TrackingError    = 0.8,
    ShakeIntensity   = 0.3,
    -- Target Override
    OverrideThreshold = 12,
    OverrideCooldown  = 0.25,
    -- Prediction tuning
    MinPredictionTime = 0.02,  -- floor prediction horizon (seconds) even at 0 ping
    -- Whitelist
    WhitelistedTeams  = {},
}

local Settings = {}
for k, v in pairs(Defaults) do Settings[k] = v end

local HardDefaults = {}
for k, v in pairs(Defaults) do HardDefaults[k] = v end
HardDefaults.WhitelistedTeams = {}

local uiResets = {}

-- ============================================================
-- [2.5] SAVE / LOAD SYSTEM
-- ============================================================
local SAVE_FILE = "AimbotSettings.json"

local SAVE_KEYS = {
    "Enabled", "EspEnabled", "PlayerEspEnabled", "EspTextEnabled", "EspTeamCheck", "EspTeamColors", "EspType", "WallCheck", "Mode", "TeamCheck", "Prediction", "TargetPart",
    "FOV", "MaxDistance", "PredictionFactor", "Smoothness", "AdaptivePrediction",
    "HealthCheckEnabled", "HealthMinHP", "HealthMaxHP",
    "MinReactionTime", "MaxReactionTime", "MeanReactionTime",
    "TrackingError", "ShakeIntensity",
    "OverrideThreshold", "OverrideCooldown",
    "MinPredictionTime",
}

local function serializeSettings()
    local t = {}
    for _, k in ipairs(SAVE_KEYS) do
        t[k] = Settings[k]
    end
    local teams = {}
    for name in pairs(Settings.WhitelistedTeams) do
        teams[#teams + 1] = name
    end
    table.sort(teams)
    t.WhitelistedTeams = teams
    return t
end

local function saveSettings()
    local ok, result = pcall(function()
        local encoded = HttpService:JSONEncode(serializeSettings())
        writefile(SAVE_FILE, encoded)
    end)
    return ok, ok or result
end

local function loadSettings()
    if not isfile(SAVE_FILE) then return end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(SAVE_FILE))
    end)
    if not ok or type(data) ~= "table" then return end

    for _, k in ipairs(SAVE_KEYS) do
        local v = data[k]
        if v ~= nil and type(v) == type(HardDefaults[k]) then
            Settings[k] = v
        end
    end

    if type(data.WhitelistedTeams) == "table" then
        table.clear(Settings.WhitelistedTeams)
        for _, name in ipairs(data.WhitelistedTeams) do
            if type(name) == "string" then
                Settings.WhitelistedTeams[name] = true
            end
        end
    end
end

loadSettings()

-- ============================================================
-- [3] PLAYER CACHE
-- ============================================================

local visCache        = {}
local targetPartCache = {}
local espBoxPool       = {}
local espCharmPool     = {}
local espHighlightPool = {}
local espTextPool      = {}

local ESP_COLOR_DEFAULT = Color3.fromRGB(255, 69, 0)

local espRenderList  = {}
local espCharCache   = {}   -- [player] = cc (character context, see onCharacter)
local espPlayerConns = {}

local function espHidePlayer(pl)
    if espBoxPool[pl]       then espBoxPool[pl].Visible       = false end
    if espCharmPool[pl]     then espCharmPool[pl].Visible     = false end
    if espHighlightPool[pl] then espHighlightPool[pl].Enabled = false end
    if espTextPool[pl] then
        espTextPool[pl].name.Visible = false
        espTextPool[pl].info.Visible = false
    end
end

local function espRemoveFromList(pl)
    for i = 1, #espRenderList do
        if espRenderList[i].pl == pl then
            espRenderList[i] = espRenderList[#espRenderList]
            espRenderList[#espRenderList] = nil
            return
        end
    end
end

local function espDestroyPools(pl)
    if espBoxPool[pl] then
        pcall(function() espBoxPool[pl]:Remove() end)
        espBoxPool[pl] = nil
    end
    if espCharmPool[pl] then
        pcall(function() espCharmPool[pl]:Remove() end)
        espCharmPool[pl] = nil
    end
    if espHighlightPool[pl] then
        pcall(function() espHighlightPool[pl]:Destroy() end)
        espHighlightPool[pl] = nil
    end
    if espTextPool[pl] then
        pcall(function() espTextPool[pl].name:Remove() end)
        pcall(function() espTextPool[pl].info:Remove() end)
        espTextPool[pl] = nil
    end
end

local function setupEspPlayer(pl)
    if pl == LocalPlayer then return end

    local state = {}

    local function onCharacter(ch)
        -- Disconnect any previous character's per-character connections
        if state.humConn          then state.humConn:Disconnect();          state.humConn          = nil end
        if state.healthConn       then state.healthConn:Disconnect();       state.healthConn       = nil end
        if state.childAddedConn   then state.childAddedConn:Disconnect();   state.childAddedConn   = nil end
        if state.childRemovedConn then state.childRemovedConn:Disconnect(); state.childRemovedConn = nil end

        -- Wait for all required parts — avoids nil-root silent skips when
        -- the character is still streaming in when CharacterAdded fires.
        local hum  = ch:WaitForChild("Humanoid",         5)
        local root = ch:WaitForChild("HumanoidRootPart", 5)
        local head = ch:WaitForChild("Head",             5)
        if not hum or not root or not head then return end
        if pl.Character ~= ch then return end   -- re-validate after all waits

        -- ── Build body-part list (direct BasePart children only).
        -- Accessories (Accessory > Handle) and Tools (Tool > Handle) live in
        -- sub-Models, so their handles do NOT appear here — giving a body-only
        -- bounding box without extra filtering in the render loop.
        -- Cached here once and kept in sync via ChildAdded/ChildRemoved so that
        -- the ESP box loop never calls GetChildren() per frame (eliminates a
        -- table allocation every frame per player).
        local bodyParts = {}
        for _, child in ipairs(ch:GetChildren()) do
            if child:IsA("BasePart") then
                bodyParts[#bodyParts + 1] = child
            end
        end

        local cc = {
            ch        = ch,
            hum       = hum,
            root      = root,
            head      = head,
            bodyParts = bodyParts,           -- cached, see above
            headHalfY = head.Size.Y * 0.5,  -- cached to avoid property read per frame in text ESP
            espHidden = false,               -- dirty flag: skip redundant Visible=false writes
            txt = {
                hpStr      = "",
                r          = 0,
                g          = 1,
                lastDist   = -1,
                colorDirty = true,
            },
        }
        espCharCache[pl] = cc

        local t = getEspText(pl)
        t.name.Text = pl.DisplayName

        local function onHealth(newHealth)
            local maxHp = mmax(hum.MaxHealth, 1)
            local hpPct = mclamp(newHealth / maxHp, 0, 1)
            cc.txt.r          = hpPct < 0.5 and 1 or (2 - hpPct * 2)
            cc.txt.g          = hpPct > 0.5 and 1 or (hpPct * 2)
            cc.txt.hpStr      = "♥ " .. mfloor(hpPct * 100 + 0.5) .. "%"
            cc.txt.colorDirty = true
        end

        onHealth(hum.Health)
        state.healthConn = hum.HealthChanged:Connect(onHealth)

        -- Keep bodyParts in sync when body parts appear/disappear (rare, but
        -- happens in morph games).
        state.childAddedConn = ch.ChildAdded:Connect(function(child)
            if child:IsA("BasePart") then
                bodyParts[#bodyParts + 1] = child
            end
        end)
        state.childRemovedConn = ch.ChildRemoved:Connect(function(child)
            if child:IsA("BasePart") then
                for i = #bodyParts, 1, -1 do
                    if bodyParts[i] == child then
                        bodyParts[i] = bodyParts[#bodyParts]
                        bodyParts[#bodyParts] = nil
                        return
                    end
                end
            end
        end)

        espRemoveFromList(pl)
        espRenderList[#espRenderList + 1] = { pl = pl, cc = cc }

        state.humConn = hum.Died:Connect(function()
            espRemoveFromList(pl)
            espHidePlayer(pl)
        end)
    end

    state.charAddedConn = pl.CharacterAdded:Connect(function(ch)
        task.spawn(onCharacter, ch)
    end)

    state.charRemovingConn = pl.CharacterRemoving:Connect(function()
        if state.humConn          then state.humConn:Disconnect();          state.humConn          = nil end
        if state.healthConn       then state.healthConn:Disconnect();       state.healthConn       = nil end
        if state.childAddedConn   then state.childAddedConn:Disconnect();   state.childAddedConn   = nil end
        if state.childRemovedConn then state.childRemovedConn:Disconnect(); state.childRemovedConn = nil end

        -- FIX: Clear character-keyed caches eagerly here instead of relying on
        -- PlayerRemoving, which fires after p.Character is already nil.  Without
        -- this, the old character Model is held alive by visCache/targetPartCache
        -- as a table key until the 5-second flush — a real memory leak.
        local cc = espCharCache[pl]
        if cc then
            visCache[cc.ch]        = nil
            targetPartCache[cc.ch] = nil
        end

        espRemoveFromList(pl)
        espHidePlayer(pl)
        espCharCache[pl] = nil
    end)

    espPlayerConns[pl] = state

    if pl.Character then
        task.spawn(onCharacter, pl.Character)
    end
end

local playerCache = {}

do
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            playerCache[#playerCache + 1] = p
            setupEspPlayer(p)
        end
    end

    Players.PlayerAdded:Connect(function(p)
        playerCache[#playerCache + 1] = p
        setupEspPlayer(p)
    end)

    Players.PlayerRemoving:Connect(function(p)
        for i = 1, #playerCache do
            if playerCache[i] == p then
                playerCache[i] = playerCache[#playerCache]
                playerCache[#playerCache] = nil
                break
            end
        end

        -- Belt-and-suspenders: charRemovingConn should have already cleared these,
        -- but p.Character can still be non-nil here if the server removes the player
        -- without a CharacterRemoving signal (edge case).
        local char = p.Character
        if char then
            visCache[char]        = nil
            targetPartCache[char] = nil
        end

        local state = espPlayerConns[p]
        if state then
            if state.charAddedConn    then state.charAddedConn:Disconnect()    end
            if state.charRemovingConn then state.charRemovingConn:Disconnect() end
            if state.humConn          then state.humConn:Disconnect()          end
            if state.healthConn       then state.healthConn:Disconnect()       end
            if state.childAddedConn   then state.childAddedConn:Disconnect()   end
            if state.childRemovedConn then state.childRemovedConn:Disconnect() end
            espPlayerConns[p] = nil
        end

        espRemoveFromList(p)
        espCharCache[p] = nil
        espDestroyPools(p)
    end)
end

-- ============================================================
-- [4] TARGET SYSTEM
-- ============================================================

local cachedScreenCenter = Vector2.new(0, 0)
local lastViewportSize   = Vector2.new(0, 0)

local function getScreenCenter()
    local vp = Camera.ViewportSize
    if vp ~= lastViewportSize then
        cachedScreenCenter = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
        lastViewportSize   = vp
    end
    return cachedScreenCenter
end

local visRayParams  = RaycastParams.new()
visRayParams.FilterType = Enum.RaycastFilterType.Blacklist

local shotRayParams = RaycastParams.new()
shotRayParams.FilterType = Enum.RaycastFilterType.Blacklist

local function refreshRayFilter()
    local char = LocalPlayer.Character
    local list = char and {char} or {}
    visRayParams.FilterDescendantsInstances  = list
    shotRayParams.FilterDescendantsInstances = list
end

refreshRayFilter()

LocalPlayer.CharacterAdded:Connect(refreshRayFilter)
LocalPlayer.CharacterRemoving:Connect(function()
    visRayParams.FilterDescendantsInstances  = {}
    shotRayParams.FilterDescendantsInstances = {}
end)

local function isVisible(targetPart, targetChar, now)
    local cached = visCache[targetChar]

    if cached and (now - cached[2]) < 0.1 then
        return cached[1]
    end

    local origin    = Camera.CFrame.Position
    local direction = targetPart.Position - origin
    local hit       = Workspace:Raycast(origin, direction, visRayParams)
    local visible   = not hit or hit.Instance:IsDescendantOf(targetChar)

    if cached then
        cached[1] = visible
        cached[2] = now
    else
        visCache[targetChar] = {visible, now}
    end

    return visible
end

local function clearTargetPartCache()
    table.clear(targetPartCache)
end

-- ── Target acquisition ────────────────────────────────────────────────────────
-- Uses espCharCache to read cached humanoid/root/head references instead of
-- calling FindFirstChildOfClass/FindFirstChild per player per frame.
-- Team checks are inlined with loop-invariant hoisting to avoid repeated
-- LocalPlayer.Team reads and isWhitelisted() call overhead.
local function getClosestTarget(now)
    local myChar = LocalPlayer.Character
    if not myChar then return nil, nil, nil, nil end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return nil, nil, nil, nil end

    local myPos      = myRoot.Position
    local sc         = getScreenCenter()
    local scX, scY   = sc.X, sc.Y
    local healthMode = Settings.HealthCheckEnabled
    local maxDist    = Settings.MaxDistance
    local maxDistSq  = maxDist * maxDist
    local fov        = Settings.FOV
    local fovSq      = fov * fov
    local wallCheck  = Settings.WallCheck

    -- Hoist all Settings reads that are invariant across the player loop
    local teamCheck = Settings.TeamCheck
    local myTeam    = teamCheck and LocalPlayer.Team or nil
    local wlTeams   = Settings.WhitelistedTeams
    local tpName    = Settings.TargetPart
    local healthMin = Settings.HealthMinHP
    local healthMax = Settings.HealthMaxHP

    local bestScore  = mhuge
    local bestPlayer, bestPart, bestRoot, bestHumanoid = nil, nil, nil, nil

    for _, player in ipairs(playerCache) do
        -- Inline team / whitelist check (avoids isWhitelisted() call overhead
        -- and the repeated LocalPlayer.Team read it contained)
        local pTeam = player.Team
        if myTeam and pTeam == myTeam then continue end
        if pTeam and wlTeams[pTeam.Name] then continue end

        -- Use cached character context — eliminates FindFirstChildOfClass("Humanoid")
        -- and FindFirstChild("HumanoidRootPart") per player per frame
        local cc = espCharCache[player]
        if not cc then continue end

        local humanoid = cc.hum
        if not humanoid or humanoid.Health <= 0 then continue end

        if healthMode then
            local maxHp = humanoid.MaxHealth
            local hpPct = maxHp > 0 and (humanoid.Health / maxHp * 100) or 0
            if hpPct < healthMin or hpPct > healthMax then continue end
        end

        -- Resolve target part from cache where possible (common cases: Head, Torso)
        local targetPart
        if tpName == "Head" then
            targetPart = cc.head
        elseif tpName == "Torso" or tpName == "HumanoidRootPart" then
            targetPart = cc.root
        elseif tpName == "Random" then
            local ch = cc.ch
            if not targetPartCache[ch] then
                targetPartCache[ch] = mrand(1, 2) == 1 and "Head" or "HumanoidRootPart"
            end
            targetPart = targetPartCache[ch] == "Head" and cc.head or cc.root
        else
            targetPart = cc.ch:FindFirstChild(tpName)
        end

        local rootPart = cc.root
        if not targetPart or not rootPart then continue end

        local dp = targetPart.Position - myPos
        if dp.X*dp.X + dp.Y*dp.Y + dp.Z*dp.Z > maxDistSq then continue end

        local screenPos, onScreen = Camera:WorldToViewportPoint(targetPart.Position)
        if not onScreen then continue end

        local dsx = screenPos.X - scX
        local dsy = screenPos.Y - scY
        local screenDistSq = dsx*dsx + dsy*dsy
        if screenDistSq >= fovSq then continue end

        local score = healthMode and humanoid.Health or msqrt(screenDistSq)

        local effectiveScore = (player == currentTarget and not healthMode)
            and (score - 15) or score

        if effectiveScore < bestScore
        and (not wallCheck or isVisible(targetPart, cc.ch, now)) then
            bestPlayer   = player
            bestPart     = targetPart
            bestRoot     = rootPart
            bestHumanoid = humanoid
            bestScore    = effectiveScore
        end
    end

    return bestPlayer, bestPart, bestRoot, bestHumanoid
end

-- ============================================================
-- [5] AIM STATE  (reaction, spring smoother, humanised tracking)
-- ============================================================

local currentTarget   = nil
local isReacting      = false
local reactionEndTime = 0
local alertnessLevel  = 0.5

local overrideActive = false
local overrideUntil  = 0

local Spr = {pos=nil, vel=ZERO3, k=0, d=0, lastS=-1}

local function refreshSpringConstants()
    local s = Settings.Smoothness
    Spr.k   = 18 + (s ^ 1.6) * 560
    Spr.d   = 0.70 * 2 * msqrt(Spr.k)
    Spr.lastS = s
end

local function resetSpring()
    Spr.pos = nil
    Spr.vel = ZERO3
end

-- ============================================================
-- [5.1] JERK-MODEL KALMAN FILTER  (4-state per axis)
-- ============================================================
-- State vector per axis: [position, velocity, acceleration, jerk]
-- Transition matrix F (dt):
--   | 1   dt  dt²/2  dt³/6 |
--   | 0   1   dt     dt²/2 |
--   | 0   0   1      dt    |
--   | 0   0   0      1     |
--
-- Observation: H = [1, 0, 0, 0]  (we observe position only)
--
-- This 4-state model natively tracks acceleration and jerk, meaning strafes,
-- jumps, bhops, and direction changes are modelled in-state rather than noise.
-- The prediction step uses all four states for a Taylor expansion giving far
-- better look-ahead during parabolic arcs and snap direction changes.

local Q_POS   = 1e-4
local Q_VEL   = 0.08
local Q_ACCEL = 2.5
local Q_JERK  = 25.0
local R_MEAS  = 0.04

local K = {
    -- Per-axis state: [pos, vel, accel, jerk]
    s = {
        {0, 0, 0, 0},
        {0, 0, 0, 0},
        {0, 0, 0, 0},
    },
    -- Per-axis 4×4 covariance (flat 16-element row-major, pre-allocated and reused in-place)
    P = {
        {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1},
        {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1},
        {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1},
    },
    init = false,
}

-- Exported for the render loop
local predSmoothedVel   = ZERO3
local predSmoothedAccel = ZERO3
local predSmoothedJerk  = ZERO3

-- Writes the 4×4 identity into an existing covariance array in-place (no alloc).
local function resetCovInPlace(P)
    P[1]=1;  P[2]=0;  P[3]=0;  P[4]=0
    P[5]=0;  P[6]=1;  P[7]=0;  P[8]=0
    P[9]=0;  P[10]=0; P[11]=1; P[12]=0
    P[13]=0; P[14]=0; P[15]=0; P[16]=1
end

-- Resets Kalman state by writing zeros into existing arrays — no allocations.
local function resetPrediction()
    for i = 1, 3 do
        local s = K.s[i]
        s[1] = 0; s[2] = 0; s[3] = 0; s[4] = 0
        resetCovInPlace(K.P[i])
    end
    K.init = false
    predSmoothedVel   = ZERO3
    predSmoothedAccel = ZERO3
    predSmoothedJerk  = ZERO3
end

-- ── Kalman predict + update  (fully inlined — ZERO table allocations) ─────────
--
-- The original implementation used mat4mul/mat4T helpers, each creating a new
-- 16-element table.  At 3 axes × ~6 allocs/call × 60 fps that was ~1,080
-- short-lived table allocations per second driving GC pressure.
--
-- This version analytically expands F×P×Fᵀ by exploiting F's upper-triangular
-- structure (only 10 of 16 elements non-zero), then writes the updated
-- covariance directly into the existing K.P[ax] array — zero allocations.
--
-- Math sketch (a=dt, b=dt²/2, c=dt³/6):
--   FP(i,j) = sum_k F(i,k)*P(k,j)   — computed row by row using F sparsity
--   PP(i,j) = sum_k FP(i,k)*Fᵀ(k,j) — Fᵀ col j = F row j
--   Kalman gain K_vec = PP[:,0] / (PP[0,0] + R)  (H=[1,0,0,0])
--   new_P(r,c) = PP(r,c) - K_vec[r] * PP(0,c)    (simplified (I-KH)*PP)
local function kalmanAxisUpdate(ax, measurement, dt)
    local s = K.s[ax]
    local P = K.P[ax]

    local a = dt
    local b = dt * dt * 0.5
    local c = dt * dt * dt * (1/6)

    -- ── State prediction: x_pred = F * x ─────────────────────────────────────
    local p_pred = s[1] + s[2]*a + s[3]*b + s[4]*c
    local v_pred = s[2] + s[3]*a + s[4]*b
    local a_pred = s[3] + s[4]*a
    local j_pred = s[4]

    -- ── FP = F × P  (4 rows, exploiting F upper-triangular sparsity) ─────────
    local fp00 = P[1]  + a*P[5]  + b*P[9]  + c*P[13]
    local fp01 = P[2]  + a*P[6]  + b*P[10] + c*P[14]
    local fp02 = P[3]  + a*P[7]  + b*P[11] + c*P[15]
    local fp03 = P[4]  + a*P[8]  + b*P[12] + c*P[16]

    local fp10 = P[5]  + a*P[9]  + b*P[13]
    local fp11 = P[6]  + a*P[10] + b*P[14]
    local fp12 = P[7]  + a*P[11] + b*P[15]
    local fp13 = P[8]  + a*P[12] + b*P[16]

    local fp20 = P[9]  + a*P[13]
    local fp21 = P[10] + a*P[14]
    local fp22 = P[11] + a*P[15]
    local fp23 = P[12] + a*P[16]

    local fp30 = P[13]
    local fp31 = P[14]
    local fp32 = P[15]
    local fp33 = P[16]

    -- ── PP = FP × Fᵀ + Q  (Fᵀ col j = F row j) ──────────────────────────────
    -- PP(i,j) = FP(i,0)*F(j,0) + FP(i,1)*F(j,1) + ...
    -- F rows: [1,a,b,c],[0,1,a,b],[0,0,1,a],[0,0,0,1]
    -- → PP col 0 = FP col 0 ; col 1 = a*FP_col0 + FP_col1 ; etc.
    local pp00 = fp00                             + Q_POS
    local pp01 = a*fp00 + fp01
    local pp02 = b*fp00 + a*fp01 + fp02
    local pp03 = c*fp00 + b*fp01 + a*fp02 + fp03

    local pp10 = fp10
    local pp11 = a*fp10 + fp11                    + Q_VEL
    local pp12 = b*fp10 + a*fp11 + fp12
    local pp13 = c*fp10 + b*fp11 + a*fp12 + fp13

    local pp20 = fp20
    local pp21 = a*fp20 + fp21
    local pp22 = b*fp20 + a*fp21 + fp22           + Q_ACCEL
    local pp23 = c*fp20 + b*fp21 + a*fp22 + fp23

    local pp30 = fp30
    local pp31 = a*fp30 + fp31
    local pp32 = b*fp30 + a*fp31 + fp32
    local pp33 = c*fp30 + b*fp31 + a*fp32 + fp33  + Q_JERK

    -- ── Kalman gain  (H=[1,0,0,0] → gain = PP[:,0] / (PP[0,0]+R)) ────────────
    local iS = 1 / (pp00 + R_MEAS)
    local K1  = pp00 * iS
    local K2  = pp10 * iS
    local K3  = pp20 * iS
    local K4  = pp30 * iS

    -- ── State update ──────────────────────────────────────────────────────────
    local innov = measurement - p_pred
    s[1] = p_pred + K1 * innov
    s[2] = v_pred + K2 * innov
    s[3] = a_pred + K3 * innov
    s[4] = j_pred + K4 * innov

    -- ── Covariance update: new_P = (I − K·H) × PP ────────────────────────────
    -- (I−KH) row 0: [1−K1, 0, 0, 0]  → new_P row 0 = (1−K1) * PP row 0
    -- (I−KH) row r>0: identity except col 0 = −Kr
    -- → new_P(r,c) = PP(r,c) − Kr × PP(0,c)
    -- Written into the existing P array in-place — zero allocations.
    local m1K1 = 1 - K1
    P[1]  = m1K1*pp00         ; P[2]  = m1K1*pp01         ; P[3]  = m1K1*pp02         ; P[4]  = m1K1*pp03
    P[5]  = pp10 - K2*pp00   ; P[6]  = pp11 - K2*pp01    ; P[7]  = pp12 - K2*pp02    ; P[8]  = pp13 - K2*pp03
    P[9]  = pp20 - K3*pp00   ; P[10] = pp21 - K3*pp01    ; P[11] = pp22 - K3*pp02    ; P[12] = pp23 - K3*pp03
    P[13] = pp30 - K4*pp00   ; P[14] = pp31 - K4*pp01    ; P[15] = pp32 - K4*pp02    ; P[16] = pp33 - K4*pp03
end

-- Main entry point: feed a world-space position, get back vel, accel, jerk.
-- Uses 3 scalar locals instead of allocating a {meas.X, meas.Y, meas.Z} table.
local function updateKalman(meas, dt)
    local mx1, mx2, mx3 = meas.X, meas.Y, meas.Z

    if not K.init then
        -- Seed state from first observation; write into existing arrays
        local s1, s2, s3 = K.s[1], K.s[2], K.s[3]
        s1[1]=mx1; s1[2]=0; s1[3]=0; s1[4]=0
        s2[1]=mx2; s2[2]=0; s2[3]=0; s2[4]=0
        s3[1]=mx3; s3[2]=0; s3[3]=0; s3[4]=0
        resetCovInPlace(K.P[1])
        resetCovInPlace(K.P[2])
        resetCovInPlace(K.P[3])
        K.init = true
        return ZERO3, ZERO3, ZERO3
    end

    -- Clamp dt to avoid numerical blow-up at very low or very high frame rates
    local safeDt = mclamp(dt, 0.001, 0.05)

    kalmanAxisUpdate(1, mx1, safeDt)
    kalmanAxisUpdate(2, mx2, safeDt)
    kalmanAxisUpdate(3, mx3, safeDt)

    local estVel   = Vector3.new(K.s[1][2], K.s[2][2], K.s[3][2])
    local estAccel = Vector3.new(K.s[1][3], K.s[2][3], K.s[3][3])
    local estJerk  = Vector3.new(K.s[1][4], K.s[2][4], K.s[3][4])

    return estVel, estAccel, estJerk
end

-- ── Kalman extrapolation helper ──────────────────────────────────────────────
-- Predicts world-space position `t` seconds ahead using the full Taylor series:
--   pos + vel*t + 0.5*accel*t² + (1/6)*jerk*t³
local function kalmanExtrapolate(t)
    local t2 = t * t
    local t3 = t2 * t
    return Vector3.new(
        K.s[1][1] + K.s[1][2]*t + 0.5*K.s[1][3]*t2 + (1/6)*K.s[1][4]*t3,
        K.s[2][1] + K.s[2][2]*t + 0.5*K.s[2][3]*t2 + (1/6)*K.s[2][4]*t3,
        K.s[3][1] + K.s[3][2]*t + 0.5*K.s[3][3]*t2 + (1/6)*K.s[3][4]*t3
    )
end

-- ============================================================
-- [5.2] CAMERA / CLIENT VELOCITY TRACKER
-- ============================================================
local camVelTracker = {
    lastPos = nil,
    vel     = ZERO3,
    alpha   = 0.3,
}

local function updateCameraVelocity(camPos, dt)
    if camVelTracker.lastPos == nil then
        camVelTracker.lastPos = camPos
        return ZERO3
    end

    local rawVel = (camPos - camVelTracker.lastPos) / mmax(dt, 0.001)
    camVelTracker.vel = camVelTracker.vel:Lerp(rawVel, camVelTracker.alpha)
    camVelTracker.lastPos = camPos
    return camVelTracker.vel
end

local function resetCameraVelocity()
    camVelTracker.lastPos = nil
    camVelTracker.vel     = ZERO3
end

-- ============================================================
-- [5.3] TARGET PART OFFSET TRACKER
-- ============================================================
local partOffsetTracker = {
    offset = ZERO3,
    alpha  = 0.35,
    init   = false,
}

local function updatePartOffset(rootPos, partPos)
    local raw = partPos - rootPos
    if not partOffsetTracker.init then
        partOffsetTracker.offset = raw
        partOffsetTracker.init   = true
    else
        partOffsetTracker.offset = partOffsetTracker.offset:Lerp(raw, partOffsetTracker.alpha)
    end
    return partOffsetTracker.offset
end

local function resetPartOffset()
    partOffsetTracker.offset = ZERO3
    partOffsetTracker.init   = false
end

-- ── Seeded fBm value noise ────────────────────────────────────────────────────
local smoothNoise
do
    local NOISE_TABLE = {}
    for i = 1, 256 do
        NOISE_TABLE[i] = mrand() * 2 - 1
    end

    local function hashLookup(i)
        return NOISE_TABLE[(i % 256) + 1]
    end

    local function catmullRom(v0, v1, v2, v3, t)
        local t2 = t * t
        local t3 = t2 * t
        return 0.5 * ( (2*v1)
                     + (-v0 + v2)                * t
                     + (2*v0 - 5*v1 + 4*v2 - v3) * t2
                     + (-v0 + 3*v1 - 3*v2 + v3)  * t3 )
    end

    local function valueNoise1D(x)
        local i    = mfloor(x)
        local frac = x - i
        return mclamp(catmullRom(
            hashLookup(i-1), hashLookup(i),
            hashLookup(i+1), hashLookup(i+2), frac), -1, 1)
    end

    smoothNoise = function(x)
        return mclamp(
            ( valueNoise1D(x)       * 0.5
            + valueNoise1D(x * 2.0) * 0.25
            + valueNoise1D(x * 4.0) * 0.125
            + valueNoise1D(x * 8.0) * 0.0625 ) * (1 / 0.9375),
        -1, 1)
    end
end

-- ── Alertness system ──────────────────────────────────────────────────────────
local trackingStartTime  = 0
local lastTargetLostTime = 0
local trackingDistance   = 200

-- ── Ping cache ────────────────────────────────────────────────────────────────
local cachedPing = 0

-- ============================================================
-- [6] UNIFIED MAINTENANCE THREAD
-- ============================================================
-- Merges the three original background threads (alertnessThread, pingThread,
-- visCacheFlushThread) into a single task.spawn.  This reduces Lua scheduler
-- overhead from 3 wakeup / context-switch cycles per 0.1 s to 1, eliminates
-- two extra tick() C-boundary crossings per wakeup, and halves total thread
-- count for the lifetime of the script.
local _mtick = 0
task.spawn(function()
    while true do
        task.wait(0.1)
        _mtick = _mtick + 1

        -- Alertness decay / ramp (every 0.1 s)
        if currentTarget == nil then
            local timeSinceLost = tick() - lastTargetLostTime
            local decayRate = timeSinceLost < 3.0 and 0.02 or 0.008
            alertnessLevel = mmax(0.2, alertnessLevel - decayRate)
        else
            local distFactor    = mclamp(1.0 - trackingDistance / mmax(Settings.MaxDistance, 1), 0.2, 1.0)
            local engageSecs    = tick() - trackingStartTime
            local durationBoost = mclamp(engageSecs / 5.0, 0, 0.5)
            local rampRate      = 0.015 * distFactor * (1.0 + durationBoost)
            if engageSecs > 30 then
                rampRate = rampRate * mclamp(1.0 - (engageSecs - 30) * 0.01, 0.6, 1.0)
            end
            alertnessLevel = mmin(1.0, alertnessLevel + rampRate)
        end

        -- Ping sample (every 0.5 s = every 5 ticks)
        if _mtick % 5 == 0 then
            cachedPing = LocalPlayer:GetNetworkPing()
        end

        -- visCache full flush (every 5 s = every 50 ticks).
        -- Safety net; charRemovingConn now clears entries eagerly on respawn,
        -- so most entries are gone before this fires.
        if _mtick >= 50 then
            table.clear(visCache)
            _mtick = 0
        end
    end
end)

-- ── Reaction time (Box-Muller) ────────────────────────────────────────────────
local function generateReactionTime()
    local u1 = mmax(mrand(), 1e-10)
    local u2 = mrand()
    local stdNormal = msqrt(-2.0 * mlog(u1)) * mcos(TAU * u2)
    local stdDev  = 0.03 + (1.0 - alertnessLevel) * 0.05
    local reaction  = Settings.MeanReactionTime + (stdNormal * stdDev)
    local modifier  = 1.0 - (alertnessLevel * 0.3)
    return mclamp(reaction * modifier, Settings.MinReactionTime, Settings.MaxReactionTime)
end

local recentTargetPlayer  = nil
local recentTargetLostAt  = -math.huge

local function onNewTargetAcquired(newTarget, now)
    if newTarget ~= currentTarget then
        local isReacq = (newTarget == recentTargetPlayer)
            and (now - recentTargetLostAt < 2.0)

        currentTarget      = newTarget
        recentTargetPlayer = newTarget
        trackingStartTime  = now
        isReacting         = true

        local baseReact = generateReactionTime()
        reactionEndTime = now + (isReacq and baseReact * 0.55 or baseReact)

        resetSpring()
        resetPrediction()
        resetCameraVelocity()
        resetPartOffset()
    end
end

local function shouldWaitForReaction(now)
    if Settings.Mode ~= "Legit" then return false end
    if isReacting then
        if now < reactionEndTime then
            return true
        else
            isReacting = false
        end
    end
    return false
end

-- ── Humanised tracking ────────────────────────────────────────────────────────
local aimBiasCenter     = ZERO3
local aimOffset         = ZERO3
local targetVelocityLag = ZERO3
local shakeTime         = 0

local function generateAimError(targetVelocity, distanceToTarget, dt)
    local df   = mclamp(distanceToTarget / Settings.MaxDistance, 0, 1)
    local dErr = df * df * Settings.TrackingError

    local velMag = targetVelocity.Magnitude
    if velMag > 0.1 then
        targetVelocityLag = targetVelocityLag:Lerp(
            targetVelocity * mclamp(velMag / 50, 0, 1) * 0.15, 0.1)
    else
        targetVelocityLag = targetVelocityLag:Lerp(ZERO3, 0.2)
    end

    shakeTime = shakeTime + dt * Settings.ShakeIntensity
    local shake = Vector3.new(
        smoothNoise(shakeTime * 6.5)       * dErr * 0.5,
        smoothNoise(shakeTime * 7.3 + 100) * dErr * 0.5,
        smoothNoise(shakeTime * 5.8 + 200) * dErr * 0.3
    )

    local diff = 0.004 * dErr
    aimBiasCenter = aimBiasCenter * (1 - 0.005) + Vector3.new(
        (mrand() - 0.5) * diff,
        (mrand() - 0.5) * diff,
        (mrand() - 0.5) * diff * 0.4
    )

    aimOffset = aimOffset:Lerp(aimBiasCenter, 0.06)

    return shake + aimOffset - targetVelocityLag
end
