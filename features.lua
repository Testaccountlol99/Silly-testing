-- [11] DRAWING SYSTEM
-- ============================================================

-- RenderProperty: creates a Drawing object of `drawType` and bulk-applies
-- every key/value pair from `props`, then returns the object.
-- Uses the module-level `newDrawing` shortcut to avoid repeated global lookups.
-- All colour values should be passed as Color3 (newC3 / Color3.fromRGB).
-- All 2-D positions/sizes should be passed as Vector2 (newV2).
local function RenderProperty(drawType, props)
    local obj = newDrawing(drawType)
    for k, v in pairs(props) do
        obj[k] = v
    end
    return obj
end

-- ── FOV circle ────────────────────────────────────────────────────────────────
-- Rendered every frame while the aimbot step is running.
local fovCircle = RenderProperty("Circle", {
    Thickness = 1,
    NumSides  = 64,
    Filled    = false,
    Visible   = false,
    Color     = newC3(1, 1, 0),   -- yellow
})

-- ── ESP box pool ──────────────────────────────────────────────────────────────
-- One Drawing "Square" per player, created on first sight and reused every
-- frame.  Indexed by Player object so PlayerRemoving can evict entries.
-- The pool table itself is declared in [10] so toggle callbacks can reach it.
local function getEspBox(player)
    if not espBoxPool[player] then
        espBoxPool[player] = RenderProperty("Square", {
            Thickness = 1,
            Filled    = false,
            Visible   = false,
            Color     = newC3(1, 0.27, 0),  -- orange
        })
    end
    return espBoxPool[player]
end

-- ── ESP circle/mark pool ──────────────────────────────────────────────────────
-- One Drawing "Circle" per player for "Circle/Mark" ESP mode.
-- Renders as a small filled dot at the player's on-screen position.
local function getEspCharm(player)
    if not espCharmPool[player] then
        espCharmPool[player] = RenderProperty("Circle", {
            Thickness = 1,
            NumSides  = 32,
            Radius    = 5,
            Filled    = true,
            Visible   = false,
            Color     = newC3(1, 0.27, 0),  -- orange (matches box colour)
        })
    end
    return espCharmPool[player]
end

-- ── ESP highlight pool ────────────────────────────────────────────────────────
-- One Highlight instance per player for "Charm" ESP mode.
-- Parented to EspHighlightHandler (inside MainFrame) so they live and die
-- with the GUI without needing explicit cleanup on every type switch.
local function getEspHighlight(player)
    if not espHighlightPool[player] then
        local hl = Instance.new("Highlight")
        hl.Name               = "EspHighlight_" .. player.Name
        hl.FillColor          = Color3.fromRGB(255, 69, 0)   -- orange fill
        hl.OutlineColor       = Color3.fromRGB(255, 255, 255) -- white outline
        hl.FillTransparency   = 0.5
        hl.OutlineTransparency = 0
        hl.Enabled            = false
        hl.Parent             = EspHighlightHandler
        espHighlightPool[player] = hl
    end
    return espHighlightPool[player]
end

-- ── ESP text pool ─────────────────────────────────────────────────────────────
-- Two Drawing "Text" objects per player:
--   name  → DisplayName, white, ~22 px above head top — set once at spawn
--   info  → "♥ HP%  •  Xm", health-coloured, ~11 px above head top
-- getEspText fills the forward declaration from core.lua so onCharacter can
-- pre-create drawings and set the player name at spawn time.
getEspText = function(player)
    if not espTextPool[player] then
        espTextPool[player] = {
            name = RenderProperty("Text", {
                Text         = "",
                Size         = 11,
                Font         = Drawing.Fonts.UI,
                Color        = newC3(1, 1, 1),
                Outline      = true,
                OutlineColor = newC3(0, 0, 0),
                Center       = true,
                Visible      = false,
            }),
            info = RenderProperty("Text", {
                Text         = "",
                Size         = 10,
                Font         = Drawing.Fonts.UI,
                Color        = newC3(0.4, 1, 0.4),
                Outline      = true,
                OutlineColor = newC3(0, 0, 0),
                Center       = true,
                Visible      = false,
            }),
        }
    end
    return espTextPool[player]
end

-- Cleanup: remove all Drawing objects on GUI teardown so they don't outlive
-- the script on executor reset.
ScreenGui.Destroying:Connect(function()
    pcall(function() fovCircle:Remove() end)
    for _, box in pairs(espBoxPool) do
        pcall(function() box:Remove() end)
    end
    for _, charm in pairs(espCharmPool) do
        pcall(function() charm:Remove() end)
    end
    -- Highlights are parented to EspHighlightHandler which is inside MainFrame /
    -- ScreenGui, so they are auto-destroyed. Explicit destroy here handles any
    -- that may have been re-parented or pools that outlive the hierarchy.
    for _, hl in pairs(espHighlightPool) do
        pcall(function() hl:Destroy() end)
    end
    for _, t in pairs(espTextPool) do
        pcall(function() t.name:Remove() end)
        pcall(function() t.info:Remove() end)
    end
end)

-- ============================================================
-- [12] AIMBOT STEP  (only runs while Enabled = true)
-- ============================================================

local aimbotConnection = nil  -- RenderStepped connection; nil when stopped

-- stopAimbot: disconnects the step, hides the FOV circle, and wipes all
-- transient aim state so nothing leaks when the aimbot is re-enabled later.
stopAimbot = function()
    if aimbotConnection then
        aimbotConnection:Disconnect()
        aimbotConnection = nil
    end
    fovCircle.Visible = false
    currentTarget     = nil
    isReacting         = false
    overrideActive     = false
    recentTargetPlayer = nil
    recentTargetLostAt = -math.huge
    lastTargetLostTime = 0
    trackingDistance   = 200
    resetSpring()
    resetPrediction()
end

-- startAimbot: connects the step. Guard against double-connect.
startAimbot = function()
    if aimbotConnection then return end
    -- Ensure spring constants are fresh before the first frame.
    refreshSpringConstants()

    aimbotConnection = RunService.RenderStepped:Connect(function(dt)
        local camCF  = Camera.CFrame
        local camPos = camCF.Position
        local now    = tick()

        -- FOV circle tracks screen centre and current FOV setting.
        local sc = getScreenCenter()
        fovCircle.Position = newV2(sc.X, sc.Y)
        fovCircle.Radius   = Settings.FOV
        fovCircle.Visible  = true

        -- ── Target acquisition ────────────────────────────────────────────────
        local targetPlayer, targetPart, rootPart, targetHumanoid =
            getClosestTarget(now)

        if targetPlayer and targetPlayer ~= currentTarget then
            onNewTargetAcquired(targetPlayer, now)
        elseif not targetPlayer then
            if currentTarget ~= nil then
                recentTargetPlayer = currentTarget
                recentTargetLostAt = now
                lastTargetLostTime = now
            end
            currentTarget = nil
            isReacting    = false
            resetSpring()
            resetPrediction()
        end

        if shouldWaitForReaction(now) then return end
        if not (targetPlayer and targetPart and rootPart and targetHumanoid) then return end

        -- ── Player override detection ─────────────────────────────────────────
        local mouseDelta = UIS:GetMouseDelta()
        if mouseDelta.Magnitude >= Settings.OverrideThreshold then
            overrideActive = true
            overrideUntil  = now + Settings.OverrideCooldown
            currentTarget  = nil
            resetSpring()
            resetPrediction()
        end

        if overrideActive then
            if now < overrideUntil then return end
            overrideActive = false
        end

                local safeDt = mclamp(dt, 0.001, 0.05)

        -- ── Kalman-filter prediction ──────────────────────────────────────────
        local rawPos = rootPart.Position
        predSmoothedVel, predSmoothedAccel = updateKalman(rawPos, safeDt)
        trackingDistance = (rawPos - camPos).Magnitude

        local isBlatant = (Settings.Mode ~= "Legit")

        -- ── Gravity prior (blatant only) ──────────────────────────────────────
        -- When the target is airborne, nudge the Kalman Y-acceleration toward
        -- Workspace.Gravity so we don't have to wait for the filter to converge.
        -- This makes falling / jumping prediction near-instant.
        if isBlatant and Settings.Prediction then
            local floorMat = targetHumanoid.FloorMaterial
            if floorMat == Enum.Material.Air then
                -- Blend Kalman accel toward gravity.  Alpha 0.35 means ~3 frames
                -- to converge from zero — fast enough for a bhop apex.
                local gravityAccel = -workspace.Gravity  -- negative Y in world space
                K.accel[2] = K.accel[2] + (gravityAccel - K.accel[2]) * 0.35
                -- Refresh the cached vector so prediction below uses the corrected value.
                predSmoothedAccel = Vector3.new(K.accel[1], K.accel[2], K.accel[3])
            end
        end

        -- ── Prediction horizon ────────────────────────────────────────────────
        local predTime
        if isBlatant then
            -- Blatant: full ping compensation, no adaptive reduction.
            -- Latency penalty is softer — only kicks in above 200 ms.
            local latPenalty = 1.0
            if cachedPing > 0.2 then
                latPenalty = mmax(0.8 - (cachedPing - 0.2) * 2.0, 0.5)
            end
            predTime = cachedPing * Settings.PredictionFactor * latPenalty
        else
            -- Legit: original adaptive logic (unchanged)
            local velMag    = predSmoothedVel.Magnitude
            local accelMag  = predSmoothedAccel.Magnitude
            local targetWalkSpeed = mmax(targetHumanoid.WalkSpeed, 1)
            local velScale   = mclamp(velMag / targetWalkSpeed, 0, 1)
            local changeRate = accelMag / mmax(velMag, 1)
            local stability  = mclamp(1 - changeRate * 0.12, 0.35, 1.0)
            local adaptiveFactor = Settings.AdaptivePrediction
                and (velScale * stability) or 1.0

            local latencyPenalty = 1.0
            if cachedPing > 0.1 then
                if cachedPing < 0.15 then
                    latencyPenalty = 1.0 - (cachedPing - 0.1) * 3.0
                elseif cachedPing < 0.2 then
                    latencyPenalty = 0.85 - (cachedPing - 0.15) * 4.0
                else
                    latencyPenalty = mmax(0.65 - (cachedPing - 0.2) * 4.0, 0.45)
                end
            end
            predTime = cachedPing * adaptiveFactor * latencyPenalty
                * Settings.PredictionFactor
        end

        -- ── Compute aim position ──────────────────────────────────────────────
        local aimPos
        if Settings.Prediction then
            if isBlatant then
                -- Full CA extrapolation — no damping.
                -- pos + vel*t + 0.5*accel*t²
                aimPos = targetPart.Position
                    + predSmoothedVel   * predTime
                    + predSmoothedAccel * (0.5 * predTime * predTime)
            else
                -- Legit: keep the original damped extrapolation.
                local accelDamping = predTime > 0.15
                    and mclamp(1.0 - (predTime - 0.15) * 5.0, 0.25, 1.0) or 1.0
                aimPos = targetPart.Position
                    + predSmoothedVel   * predTime
                    + predSmoothedAccel * (0.5 * predTime * predTime * accelDamping)
            end
        else
            aimPos = targetPart.Position
        end

        -- ── Legit-mode aim error (unchanged) ─────────────────────────────────
        if Settings.Mode == "Legit" then
            local dist = (targetPart.Position - camPos).Magnitude
            aimPos = aimPos + generateAimError(predSmoothedVel, dist, dt)
        end

        -- ── Occlusion correction ──────────────────────────────────────────────
        local aimDir  = (aimPos - camPos).Unit
        local aimDist = (aimPos - camPos).Magnitude
        local preShotCheck = Workspace:Raycast(camPos, aimDir * aimDist, shotRayParams)

        if preShotCheck and preShotCheck.Instance then
            local hitPart = preShotCheck.Instance
            local hitChar = hitPart:FindFirstAncestorOfClass("Model")
            if hitChar == targetPlayer.Character and hitPart ~= targetPart then
                aimPos = aimPos:Lerp(targetPart.Position, 0.7)
            end
        end

        -- ── Spring-damper smoothing ───────────────────────────────────────────
        if Spr.pos == nil then
            Spr.pos = camPos + camCF.LookVector * 200
        end

        if Settings.Smoothness ~= Spr.lastS then
            refreshSpringConstants()
        end

        local springForce = (aimPos - Spr.pos) * Spr.k
                          - Spr.vel * Spr.d
        -- ±3% jitter simulates natural wrist inconsistency
        springForce = springForce * (1 + (mrand() - 0.5) * 0.06)

        Spr.vel = Spr.vel + springForce * safeDt
        Spr.pos = Spr.pos + Spr.vel    * safeDt

        Camera.CFrame = CFrame.new(camPos, Spr.pos)
    end)
end

-- ============================================================
-- [12b] ESP STEP  (independent of aimbot — own connection)
-- ============================================================

-- All 8 sign combinations for OBB corner enumeration.
-- Declared once here so the table is never re-allocated inside the hot loop.
local CORNER_SIGNS = {
    { 1,  1,  1}, { 1,  1, -1}, { 1, -1,  1}, { 1, -1, -1},
    {-1,  1,  1}, {-1,  1, -1}, {-1, -1,  1}, {-1, -1, -1},
}

local espConnection = nil

stopEsp = function()
    if espConnection then
        espConnection:Disconnect()
        espConnection = nil
    end
    -- Hide everything still visible. espRenderList contains only alive players
    -- but their drawings may be shown — hide them all immediately.
    for _, entry in ipairs(espRenderList) do
        espHidePlayer(entry.pl)
    end
    -- Sweep pools for any stragglers.
    for _, box   in pairs(espBoxPool)       do box.Visible   = false end
    for _, charm in pairs(espCharmPool)     do charm.Visible = false end
    for _, hl    in pairs(espHighlightPool) do hl.Enabled    = false end
    for _, t     in pairs(espTextPool) do
        t.name.Visible = false ; t.info.Visible = false
    end
end

startEsp = function()
    if espConnection then return end

    espConnection = RunService.RenderStepped:Connect(function()

        -- ── Frame-constant hoists ─────────────────────────────────────────────
        local playerEspOn = Settings.PlayerEspEnabled
        local espType     = Settings.EspType
        local textOn      = Settings.EspTextEnabled
        local teamCheck   = Settings.EspTeamCheck
        local teamColors  = Settings.EspTeamColors
        local myTeam      = LocalPlayer.Team
        local camPos      = Camera.CFrame.Position

        -- ── Bulk early-exit ───────────────────────────────────────────────────
        if not playerEspOn then
            for _, entry in ipairs(espRenderList) do
                espHidePlayer(entry.pl)
            end
            return
        end

        -- ── Main render loop ──────────────────────────────────────────────────
        -- espRenderList only contains alive players with loaded characters.
        -- Text is now event+threshold driven — no throttle counter needed.
        for i = 1, #espRenderList do
            local entry = espRenderList[i]
            local pl    = entry.pl
            local cc    = entry.cc

            -- Team filter: hide inline and skip.
            if teamCheck and myTeam and pl.Team == myTeam then
                espHidePlayer(pl)
                continue
            end

            local root = cc.root
            if not root then continue end  -- safety; shouldn't happen

            -- Single cheap root Z-check: skips all expensive work for players
            -- behind the camera. For Box mode, saves 8 viewport calls per player.
            local rsp         = Camera:WorldToViewportPoint(root.Position)
            local rootVisible = rsp.Z > 0

            -- Colour resolved once per player — no Color3 alloc when team colours OFF.
            local drawColor = (teamColors and pl.Team)
                and pl.Team.TeamColor.Color
                or  ESP_COLOR_DEFAULT

            -- ── ESP type ─────────────────────────────────────────────────────
            if espType == "Box" then
                if rootVisible then
                    local bbCF, bbSize = cc.ch:GetBoundingBox()
                    local hx = bbSize.X * 0.5
                    local hy = bbSize.Y * 0.5
                    local hz = bbSize.Z * 0.5
                    local minSX, minSY =  mhuge,  mhuge
                    local maxSX, maxSY = -mhuge, -mhuge
                    local frontCount   = 0
                    for _, s in ipairs(CORNER_SIGNS) do
                        local wp = bbCF:PointToWorldSpace(
                            Vector3.new(s[1]*hx, s[2]*hy, s[3]*hz))
                        local sp = Camera:WorldToViewportPoint(wp)
                        if sp.Z > 0 then
                            frontCount = frontCount + 1
                            if sp.X < minSX then minSX = sp.X end
                            if sp.X > maxSX then maxSX = sp.X end
                            if sp.Y < minSY then minSY = sp.Y end
                            if sp.Y > maxSY then maxSY = sp.Y end
                        end
                    end
                    if frontCount > 0 and maxSY > minSY then
                        local box = getEspBox(pl)
                        box.Size     = newV2(maxSX - minSX, maxSY - minSY)
                        box.Position = newV2(minSX, minSY)
                        box.Color    = drawColor
                        box.Visible  = true
                    else
                        if espBoxPool[pl] then espBoxPool[pl].Visible = false end
                    end
                else
                    if espBoxPool[pl] then espBoxPool[pl].Visible = false end
                end
                if espCharmPool[pl]     then espCharmPool[pl].Visible     = false end
                if espHighlightPool[pl] then espHighlightPool[pl].Enabled = false end

            elseif espType == "Circle/Mark" then
                -- rsp already computed above — reuse directly.
                if rootVisible then
                    local charm = getEspCharm(pl)
                    charm.Position = newV2(rsp.X, rsp.Y)
                    charm.Color    = drawColor
                    charm.Visible  = true
                else
                    if espCharmPool[pl] then espCharmPool[pl].Visible = false end
                end
                if espBoxPool[pl]       then espBoxPool[pl].Visible       = false end
                if espHighlightPool[pl] then espHighlightPool[pl].Enabled = false end

            elseif espType == "Charm" then
                local hl = getEspHighlight(pl)
                hl.Adornee   = cc.ch
                hl.FillColor = drawColor
                hl.Enabled   = true
                if espBoxPool[pl]   then espBoxPool[pl].Visible   = false end
                if espCharmPool[pl] then espCharmPool[pl].Visible = false end
            end

            -- ── Text overlay ──────────────────────────────────────────────────
            -- Health data (hpStr, r, g, colorDirty) is pre-computed by
            -- HealthChanged and lives in cc.txt — zero health math here.
            -- The info string is rebuilt only when the integer metre distance
            -- changes OR colorDirty is set (health changed) — not every frame.
            -- t.name.Text was set once at spawn and is never touched here.
            local head = cc.head
            if textOn and head then
                local headTop = head.Position + Vector3.new(0, head.Size.Y * 0.5, 0)
                local sp, onScreen = Camera:WorldToViewportPoint(headTop)

                if onScreen and sp.Z > 0 then
                    local t   = getEspText(pl)
                    local txt = cc.txt

                    -- Position: cheap V2 assignment every frame so text tracks movement.
                    t.name.Position = newV2(sp.X, sp.Y - 22)
                    t.info.Position = newV2(sp.X, sp.Y - 11)
                    t.name.Visible  = true
                    t.info.Visible  = true

                    -- Distance: one magnitude + floor — fast intrinsic.
                    -- Only rebuild the info string when the integer metre value
                    -- changes OR a HealthChanged event has set colorDirty.
                    local dist = mfloor((root.Position - camPos).Magnitude + 0.5)
                    if dist ~= txt.lastDist or txt.colorDirty then
                        txt.lastDist   = dist
                        txt.colorDirty = false
                        t.info.Text    = txt.hpStr .. "  •  " .. dist .. "m"
                        t.info.Color   = newC3(txt.r, txt.g, 0)
                    end
                else
                    if espTextPool[pl] then
                        espTextPool[pl].name.Visible = false
                        espTextPool[pl].info.Visible = false
                    end
                end
            elseif espTextPool[pl] then
                espTextPool[pl].name.Visible = false
                espTextPool[pl].info.Visible = false
            end
        end
        -- No hide-pass: Humanoid.Died and CharacterRemoving call espHidePlayer
        -- immediately, so the loop never encounters a dead or gone player.
    end)
end

-- Also disconnect both connections on GUI destroy.
ScreenGui.Destroying:Connect(stopAimbot)
ScreenGui.Destroying:Connect(stopEsp)

-- ============================================================
-- [13] BOOT  — apply saved settings to UI and start if enabled
-- ============================================================
-- All sections (including startAimbot/stopAimbot in [12]) are now defined,
-- so it is safe to call applySettingsToUI which fires widget callbacks.
applySettingsToUI()

