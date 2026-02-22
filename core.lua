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
local espCharCache   = {}
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
        if state.humConn    then state.humConn:Disconnect();    state.humConn    = nil end
        if state.healthConn then state.healthConn:Disconnect(); state.healthConn = nil end

        local hum = ch:WaitForChild("Humanoid", 5)
        if not hum then return end
        if pl.Character ~= ch then return end

        local cc = {
            ch   = ch,
            hum  = hum,
            root = ch:FindFirstChild("HumanoidRootPart"),
            head = ch:FindFirstChild("Head"),
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
        if state.humConn    then state.humConn:Disconnect();    state.humConn    = nil end
        if state.healthConn then state.healthConn:Disconnect(); state.healthConn = nil end
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

local visCacheFlushThread = task.spawn(function()
    while true do
        task.wait(5)
        table.clear(visCache)
    end
end)

local function clearTargetPartCache()
    table.clear(targetPartCache)
end

local function getTargetPart(character)
    local name = Settings.TargetPart
    if name == "Random" then
        if not targetPartCache[character] then
            targetPartCache[character] = mrand(1, 2) == 1 and "Head" or "HumanoidRootPart"
        end
        return character:FindFirstChild(targetPartCache[character])
    elseif name == "Torso" then
        return character:FindFirstChild("HumanoidRootPart")
    else
        return character:FindFirstChild(name)
    end
end

local function isWhitelisted(player)
    local playerTeam = player.Team

    if Settings.TeamCheck then
        local myTeam = LocalPlayer.Team
        if myTeam ~= nil and playerTeam == myTeam then
            return true
        end
    end

    if playerTeam and Settings.WhitelistedTeams[playerTeam.Name] then
        return true
    end

    return false
end

local function getClosestTarget(now)
    local myChar = LocalPlayer.Character
    if not myChar then return nil, nil, nil, nil end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return nil, nil, nil, nil end

    local myPos        = myRoot.Position
    local screenCenter = getScreenCenter()
    local scX          = screenCenter.X
    local scY          = screenCenter.Y
    local healthMode   = Settings.HealthCheckEnabled

    local maxDist   = Settings.MaxDistance
    local maxDistSq = maxDist * maxDist
    local fov       = Settings.FOV
    local fovSq     = fov * fov

    local bestScore  = mhuge
    local bestPlayer, bestPart, bestRoot, bestHumanoid = nil, nil, nil, nil

    for _, player in ipairs(playerCache) do
        if isWhitelisted(player) then continue end

        local char = player.Character
        if not char then continue end

        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 then continue end

        if healthMode then
            local maxHp = humanoid.MaxHealth
            local hpPct = maxHp > 0 and (humanoid.Health / maxHp * 100) or 0
            if hpPct < Settings.HealthMinHP or hpPct > Settings.HealthMaxHP then continue end
        end

        local targetPart = getTargetPart(char)
        local rootPart   = char:FindFirstChild("HumanoidRootPart")
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
        and (not Settings.WallCheck or isVisible(targetPart, char, now)) then
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
-- This 4-state model natively tracks acceleration and jerk, meaning
-- strafes, jumps, bhops, and direction changes are modelled in-state
-- rather than treated as noise.  The prediction step uses all four
-- states for a proper Taylor expansion, which gives far better
-- look-ahead during parabolic arcs (jumps/falls) and snap direction
-- changes (strafes/bhops).

-- Process noise covariance Q diagonal (tuned for Roblox character dynamics):
--   Q_POS   = 1e-4   (position is well-observed, low process noise)
--   Q_VEL   = 0.08   (velocity changes moderately)
--   Q_ACCEL = 2.5    (acceleration changes frequently — strafe/jump)
--   Q_JERK  = 25.0   (jerk is very noisy — snap direction changes)
-- Measurement noise R = 0.04  (Roblox positions are fairly clean)
--
-- Higher Q_ACCEL and Q_JERK make the filter MORE responsive to manoeuvres
-- at the cost of slightly noisier steady-state — exactly the trade-off we want.

local Q_POS   = 1e-4
local Q_VEL   = 0.08
local Q_ACCEL = 2.5
local Q_JERK  = 25.0
local R_MEAS  = 0.04

local K = {
    -- Per-axis state: [pos, vel, accel, jerk]
    s = {
        {0, 0, 0, 0},  -- X
        {0, 0, 0, 0},  -- Y
        {0, 0, 0, 0},  -- Z
    },
    -- Per-axis 4x4 covariance (flat 16-element array, row-major)
    P = {nil, nil, nil},
    init = false,
}

-- Create a fresh 4x4 identity-ish covariance matrix
local function newCovMatrix()
    return {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    }
end

K.P[1] = newCovMatrix()
K.P[2] = newCovMatrix()
K.P[3] = newCovMatrix()

-- Exported for the render loop
local predSmoothedVel   = ZERO3
local predSmoothedAccel = ZERO3
local predSmoothedJerk  = ZERO3

local function resetPrediction()
    for i = 1, 3 do
        K.s[i] = {0, 0, 0, 0}
        K.P[i] = newCovMatrix()
    end
    K.init = false
    predSmoothedVel   = ZERO3
    predSmoothedAccel = ZERO3
    predSmoothedJerk  = ZERO3
end

-- 4x4 matrix multiply helper (flat arrays, row-major).
-- Only used during Kalman update — not per-element hot path.
local function mat4mul(A, B)
    local C = {}
    for r = 0, 3 do
        for c = 0, 3 do
            local sum = 0
            for k = 0, 3 do
                sum = sum + A[r*4 + k + 1] * B[k*4 + c + 1]
            end
            C[r*4 + c + 1] = sum
        end
    end
    return C
end

-- 4x4 matrix transpose (flat arrays)
local function mat4T(M)
    return {
        M[1], M[5], M[9],  M[13],
        M[2], M[6], M[10], M[14],
        M[3], M[7], M[11], M[15],
        M[4], M[8], M[12], M[16],
    }
end

-- Runs the full Kalman predict+update for one axis.
-- Returns nothing; mutates K.s[ax] and K.P[ax] in place.
local function kalmanAxisUpdate(ax, measurement, dt)
    local s = K.s[ax]
    local P = K.P[ax]

    local dt2 = dt * dt
    local dt3 = dt2 * dt
    local halfDt2 = dt2 * 0.5
    local sixthDt3 = dt3 / 6.0

    -- ── PREDICT ──────────────────────────────────────────────────────────────
    -- State prediction: x_pred = F * x
    local p_pred = s[1] + s[2]*dt + s[3]*halfDt2 + s[4]*sixthDt3
    local v_pred = s[2] + s[3]*dt + s[4]*halfDt2
    local a_pred = s[3] + s[4]*dt
    local j_pred = s[4]

    -- Covariance prediction: P_pred = F * P * F^T + Q
    -- Build F matrix
    local F = {
        1,  dt,  halfDt2, sixthDt3,
        0,  1,   dt,      halfDt2,
        0,  0,   1,       dt,
        0,  0,   0,       1,
    }
    local FT = mat4T(F)
    local FP = mat4mul(F, P)
    local PP = mat4mul(FP, FT)

    -- Add process noise Q (diagonal)
    PP[1]  = PP[1]  + Q_POS
    PP[6]  = PP[6]  + Q_VEL
    PP[11] = PP[11] + Q_ACCEL
    PP[16] = PP[16] + Q_JERK

    -- ── UPDATE ───────────────────────────────────────────────────────────────
    -- Innovation: y = z - H * x_pred   (H = [1, 0, 0, 0])
    local innov = measurement - p_pred

    -- Innovation covariance: S = H * P_pred * H^T + R = PP[1] + R
    local S = PP[1] + R_MEAS

    -- Kalman gain: K = P_pred * H^T / S   → first column of PP / S
    local K1 = PP[1]  / S
    local K2 = PP[5]  / S
    local K3 = PP[9]  / S
    local K4 = PP[13] / S

    -- State update: x = x_pred + K * innov
    K.s[ax][1] = p_pred + K1 * innov
    K.s[ax][2] = v_pred + K2 * innov
    K.s[ax][3] = a_pred + K3 * innov
    K.s[ax][4] = j_pred + K4 * innov

    -- Covariance update: P = (I - K*H) * P_pred
    -- K*H is a 4x4 where only column 1 is non-zero: col1 = [K1,K2,K3,K4]
    -- (I - K*H)[r][c] = I[r][c] - Kr * H[c] = I[r][c] - Kr * (c==1 ? 1 : 0)
    -- So only column 1 of (I-KH) differs from identity.
    local IKH = {
        1-K1, 0, 0, 0,
        -K2,  1, 0, 0,
        -K3,  0, 1, 0,
        -K4,  0, 0, 1,
    }
    K.P[ax] = mat4mul(IKH, PP)
end

-- Main entry point: feed a world-space position, get back vel, accel, jerk.
local function updateKalman(meas, dt)
    local mx = {meas.X, meas.Y, meas.Z}

    if not K.init then
        for i = 1, 3 do
            K.s[i] = {mx[i], 0, 0, 0}
            K.P[i] = newCovMatrix()
        end
        K.init = true
        return ZERO3, ZERO3, ZERO3
    end

    -- Clamp dt to avoid numerical issues
    local safeDt = mclamp(dt, 0.001, 0.05)

    for i = 1, 3 do
        kalmanAxisUpdate(i, mx[i], safeDt)
    end

    local estVel   = Vector3.new(K.s[1][2], K.s[2][2], K.s[3][2])
    local estAccel = Vector3.new(K.s[1][3], K.s[2][3], K.s[3][3])
    local estJerk  = Vector3.new(K.s[1][4], K.s[2][4], K.s[3][4])

    return estVel, estAccel, estJerk
end

-- ── Kalman extrapolation helper ──────────────────────────────────────────────
-- Given the current Kalman state, produce the predicted world-space position
-- `t` seconds into the future using the full Taylor expansion:
--   pos + vel*t + 0.5*accel*t² + (1/6)*jerk*t³
-- This is used for the aim point and is the key improvement over the old
-- vel*t + 0.5*accel*t² formula.
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
-- Tracks the local player's own movement so prediction can compensate for
-- relative motion.  Uses a simple EMA on camera position delta.
local camVelTracker = {
    lastPos = nil,
    vel     = ZERO3,    -- smoothed camera velocity (world-space)
    alpha   = 0.3,      -- EMA smoothing factor (higher = more responsive)
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
-- Tracks the offset from HumanoidRootPart to the target part (e.g. Head)
-- and smooths it with an EMA.  During jumps/falls/animations the head bobs
-- relative to the root — this tracker prevents the prediction (which is
-- computed on the root) from aiming at a stale head position.
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

local alertnessThread = task.spawn(function()
    while true do
        task.wait(0.1)
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

-- ============================================================
-- [6] PING CACHE
-- ============================================================
local cachedPing = 0

local pingThread = task.spawn(function()
    while true do
        task.wait(0.5)
        cachedPing = LocalPlayer:GetNetworkPing()
    end
end)
