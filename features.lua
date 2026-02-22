-- [11] DRAWING SYSTEM
-- ============================================================

local function RenderProperty(drawType, props)
    local obj = newDrawing(drawType)
    for k, v in pairs(props) do
        obj[k] = v
    end
    return obj
end

local fovCircle = RenderProperty("Circle", {
    Thickness = 1,
    NumSides  = 64,
    Filled    = false,
    Visible   = false,
    Color     = newC3(1, 1, 0),
})

local function getEspBox(player)
    if not espBoxPool[player] then
        espBoxPool[player] = RenderProperty("Square", {
            Thickness = 1,
            Filled    = false,
            Visible   = false,
            Color     = newC3(1, 0.27, 0),
        })
    end
    return espBoxPool[player]
end

local function getEspCharm(player)
    if not espCharmPool[player] then
        espCharmPool[player] = RenderProperty("Circle", {
            Thickness = 1,
            NumSides  = 32,
            Radius    = 5,
            Filled    = true,
            Visible   = false,
            Color     = newC3(1, 0.27, 0),
        })
    end
    return espCharmPool[player]
end

local function getEspHighlight(player)
    if not espHighlightPool[player] then
        local hl = Instance.new("Highlight")
        hl.Name               = "EspHighlight_" .. player.Name
        hl.FillColor          = Color3.fromRGB(255, 69, 0)
        hl.OutlineColor       = Color3.fromRGB(255, 255, 255)
        hl.FillTransparency   = 0.5
        hl.OutlineTransparency = 0
        hl.Enabled            = false
        hl.Parent             = EspHighlightHandler
        espHighlightPool[player] = hl
    end
    return espHighlightPool[player]
end

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

ScreenGui.Destroying:Connect(function()
    pcall(function() fovCircle:Remove() end)
    for _, box in pairs(espBoxPool) do
        pcall(function() box:Remove() end)
    end
    for _, charm in pairs(espCharmPool) do
        pcall(function() charm:Remove() end)
    end
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

local aimbotConnection = nil

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
    resetCameraVelocity()
    resetPartOffset()
end

startAimbot = function()
    if aimbotConnection then return end
    refreshSpringConstants()

    aimbotConnection = RunService.RenderStepped:Connect(function(dt)
        local camCF  = Camera.CFrame
        local camPos = camCF.Position
        local now    = tick()

        local sc = getScreenCenter()
        fovCircle.Position = newV2(sc.X, sc.Y)
        fovCircle.Radius   = Settings.FOV
        fovCircle.Visible  = true

        -- ── Camera velocity (client motion compensation) ──────────────────────
        local camVel = updateCameraVelocity(camPos, dt)

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
            resetCameraVelocity()
            resetPartOffset()
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
            resetCameraVelocity()
            resetPartOffset()
        end

        if overrideActive then
            if now < overrideUntil then return end
            overrideActive = false
        end

        local safeDt = mclamp(dt, 0.001, 0.05)

        -- ── Kalman-filter update (jerk model, feeds ROOT position) ────────────
        local rootPos = rootPart.Position
        predSmoothedVel, predSmoothedAccel, predSmoothedJerk = updateKalman(rootPos, safeDt)
        trackingDistance = (rootPos - camPos).Magnitude

        -- ── Part offset tracking (head/target relative to root) ───────────────
        local partOffset = updatePartOffset(rootPos, targetPart.Position)

        -- ── Prediction horizon computation ────────────────────────────────────
        local velMag   = predSmoothedVel.Magnitude
        local accelMag = predSmoothedAccel.Magnitude

        local targetWalkSpeed = mmax(targetHumanoid.WalkSpeed, 1)
        local velScale   = mclamp(velMag / targetWalkSpeed, 0, 1)
        local changeRate = accelMag / mmax(velMag, 1)
        local stability  = mclamp(1 - changeRate * 0.08, 0.4, 1.0)

        local adaptiveFactor = Settings.AdaptivePrediction
            and (velScale * stability) or 1.0

        -- Minimum prediction floor: even at 0 ping, rendering + input pipeline
        -- introduces ~1-3 frames of latency.  This ensures we always lead by
        -- at least MinPredictionTime seconds.
        local basePing = mmax(cachedPing, Settings.MinPredictionTime)

        -- Latency penalty: smoothly reduces prediction horizon at high ping
        -- to avoid overshoot from extrapolating too far into uncertain futures.
        local latencyPenalty = 1.0
        if basePing > 0.1 then
            if basePing < 0.15 then
                latencyPenalty = 1.0 - (basePing - 0.1) * 2.0
            elseif basePing < 0.25 then
                latencyPenalty = 0.9 - (basePing - 0.15) * 2.0
            else
                latencyPenalty = mmax(0.7 - (basePing - 0.25) * 1.5, 0.5)
            end
        end

        local predTime = basePing * adaptiveFactor * latencyPenalty
            * Settings.PredictionFactor

        -- ── Kalman extrapolation (full jerk-model Taylor series) ──────────────
        -- This replaces the old manual pos + vel*t + 0.5*a*t² formula.
        -- The jerk model natively gives: pos + vel*t + 0.5*accel*t² + (1/6)*jerk*t³
        -- which accurately tracks parabolic arcs (jump/fall) and snap direction
        -- changes (strafe/bhop) without needing to clamp or damp the accel term.
        local predictedRootPos = Settings.Prediction
            and kalmanExtrapolate(predTime)
            or  rootPos

        -- ── Camera compensation ───────────────────────────────────────────────
        -- When the local player is moving (strafing, falling, bhopping), the
        -- camera will be at a different position by the time the shot registers.
        -- Shift the aim point by the camera's own velocity × prediction time
        -- to compensate for this relative motion.
        local camCompensation = ZERO3
        if Settings.Prediction then
            local camSpeed = camVel.Magnitude
            -- Only compensate when we're actually moving meaningfully
            -- (avoids jitter when standing still).
            if camSpeed > 2.0 then
                camCompensation = camVel * predTime * 0.65
                -- 0.65 factor: partial compensation prevents overcorrection
                -- since camera velocity is slightly delayed (EMA smoothed).
            end
        end

        -- ── Final aim position ────────────────────────────────────────────────
        -- predicted root + smoothed part offset + camera compensation + error
        local aimPos = predictedRootPos + partOffset + camCompensation

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
                -- Blend back toward the actual current part position if the
                -- predicted position would hit the wrong body part / geometry.
                aimPos = aimPos:Lerp(targetPart.Position, 0.6)
            elseif hitChar ~= targetPlayer.Character then
                -- Prediction overshoots into a wall/obstacle — snap closer to
                -- the raw target position to stay on the visible body.
                aimPos = aimPos:Lerp(targetPart.Position, 0.85)
            end
        end

        -- ── Spring-damper smoothing ───────────────────────────────────────────
        -- Retained in BOTH modes: Blatant gets the spring + micro-jitter,
        -- Legit gets spring + jitter + humanised error (from above).
        if Spr.pos == nil then
            Spr.pos = camPos + camCF.LookVector * 200
        end

        if Settings.Smoothness ~= Spr.lastS then
            refreshSpringConstants()
        end

        local springForce = (aimPos - Spr.pos) * Spr.k
                          - Spr.vel * Spr.d
        -- ±3% jitter simulates natural wrist inconsistency (both modes)
        springForce = springForce * (1 + (mrand() - 0.5) * 0.06)

        Spr.vel = Spr.vel + springForce * safeDt
        Spr.pos = Spr.pos + Spr.vel    * safeDt

        Camera.CFrame = CFrame.new(camPos, Spr.pos)
    end)
end

-- ============================================================
-- [12b] ESP STEP  (independent of aimbot — own connection)
-- ============================================================

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
    for _, entry in ipairs(espRenderList) do
        espHidePlayer(entry.pl)
    end
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

        local playerEspOn = Settings.PlayerEspEnabled
        local espType     = Settings.EspType
        local textOn      = Settings.EspTextEnabled
        local teamCheck   = Settings.EspTeamCheck
        local teamColors  = Settings.EspTeamColors
        local myTeam      = LocalPlayer.Team
        local camPos      = Camera.CFrame.Position

        if not playerEspOn then
            for _, entry in ipairs(espRenderList) do
                espHidePlayer(entry.pl)
            end
            return
        end

        for i = 1, #espRenderList do
            local entry = espRenderList[i]
            local pl    = entry.pl
            local cc    = entry.cc

            if teamCheck and myTeam and pl.Team == myTeam then
                espHidePlayer(pl)
                continue
            end

            local root = cc.root
            if not root then continue end

            local rsp         = Camera:WorldToViewportPoint(root.Position)
            local rootVisible = rsp.Z > 0

            local drawColor = (teamColors and pl.Team)
                and pl.Team.TeamColor.Color
                or  ESP_COLOR_DEFAULT

            if espType == "Box" then
                if rootVisible then
                    -- Compute screen-space AABB using only the character's direct
                    -- BasePart children.  Accessories (Accessory > Handle) and
                    -- held tools (Tool > Handle) are parented inside their own
                    -- sub-Model/Accessory container, so their Handle parts do NOT
                    -- appear as direct children here — giving a body-only box.
                    local minSX, minSY =  mhuge,  mhuge
                    local maxSX, maxSY = -mhuge, -mhuge
                    local frontCount   = 0
                    for _, part in ipairs(cc.ch:GetChildren()) do
                        if part:IsA("BasePart") then
                            local cf   = part.CFrame
                            local size = part.Size
                            local hx   = size.X * 0.5
                            local hy   = size.Y * 0.5
                            local hz   = size.Z * 0.5
                            for _, s in ipairs(CORNER_SIGNS) do
                                local wp = cf:PointToWorldSpace(
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

            local head = cc.head
            if textOn and head then
                local headTop = head.Position + Vector3.new(0, head.Size.Y * 0.5, 0)
                local sp, onScreen = Camera:WorldToViewportPoint(headTop)

                if onScreen and sp.Z > 0 then
                    local t   = getEspText(pl)
                    local txt = cc.txt

                    t.name.Position = newV2(sp.X, sp.Y - 22)
                    t.info.Position = newV2(sp.X, sp.Y - 11)
                    t.name.Visible  = true
                    t.info.Visible  = true

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
    end)
end

ScreenGui.Destroying:Connect(stopAimbot)
ScreenGui.Destroying:Connect(stopEsp)

-- ============================================================
-- [13] BOOT
-- ============================================================
applySettingsToUI()
