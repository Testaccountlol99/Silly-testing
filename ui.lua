-- ============================================================
-- [7] UI SETUP
-- ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name         = "AimbotUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent       = (pcall(function() return gethui() end) and gethui())
                         or game:GetService("CoreGui")

-- FIX: Cancel background threads and remove Drawing objects when the GUI is
-- torn down (executor reset, script re-run).  Without this, each run leaves
-- orphaned coroutines and drawing objects that waste CPU/memory indefinitely.
-- pcall guards against task.cancel erroring on an already-dead thread.
ScreenGui.Destroying:Connect(function()
    pcall(task.cancel, alertnessThread)
    pcall(task.cancel, pingThread)
    pcall(task.cancel, visCacheFlushThread)
end)

local MainFrame = Instance.new("Frame")
MainFrame.Name             = "MainFrame"
MainFrame.Size             = UDim2.new(0.5, 0, 1, 0)
MainFrame.Position         = UDim2.new(0.24, 0, 0.21, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
MainFrame.BorderSizePixel  = 0
MainFrame.Active           = true
MainFrame.Draggable        = true
MainFrame.Visible          = false
MainFrame.Parent           = ScreenGui
do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 6) c.Parent = MainFrame end

-- Folder that owns all Highlight instances (Charm ESP mode).
-- Lives inside MainFrame so it is automatically destroyed with the GUI.
local EspHighlightHandler = Instance.new("Folder")
EspHighlightHandler.Name   = "EspHighlightHandler"
EspHighlightHandler.Parent = MainFrame

local ToggleButton = Instance.new("TextButton")
ToggleButton.Name             = "MiniToggle"
ToggleButton.Size             = UDim2.new(0, 38, 0, 38)
ToggleButton.Position         = UDim2.new(0, 8, 0, 8)
ToggleButton.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
ToggleButton.Text             = "☰"
ToggleButton.TextColor3       = Color3.new(1, 1, 1)
ToggleButton.Font             = Enum.Font.GothamBold
ToggleButton.TextSize         = 18
ToggleButton.Parent           = ScreenGui
do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 8) c.Parent = ToggleButton end

do
    local dragging, isDragging = false, false
    local dragStart, startPos

    ToggleButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging   = true
            isDragging = false
            dragStart  = input.Position
            startPos   = ToggleButton.Position
        end
    end)

    ToggleButton.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            if not isDragging then
                MainFrame.Visible = not MainFrame.Visible
                ToggleButton.Text = MainFrame.Visible and "✕" or "☰"
            end
        end
    end)

    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - dragStart
        if delta.Magnitude > 10 then isDragging = true end
        ToggleButton.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end)
end

do  -- TitleBar and its children are not referenced after this block
    local TitleBar = Instance.new("Frame")
    TitleBar.Size             = UDim2.new(1, 0, 0, 32)
    TitleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    TitleBar.BorderSizePixel  = 0
    TitleBar.Parent           = MainFrame
    do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 6) c.Parent = TitleBar end

    local fix = Instance.new("Frame")
    fix.Size             = UDim2.new(1, 0, 0, 5)
    fix.Position         = UDim2.new(0, 0, 1, -5)
    fix.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    fix.BorderSizePixel  = 0
    fix.Parent           = TitleBar

    local lbl = Instance.new("TextLabel")
    lbl.Text                   = "AIMBOT SETTINGS"
    lbl.TextColor3             = Color3.new(1, 1, 1)
    lbl.Font                   = Enum.Font.GothamBold
    lbl.TextSize               = 13
    lbl.BackgroundTransparency = 1
    lbl.Size                   = UDim2.new(1, 0, 1, 0)
    lbl.Parent                 = TitleBar
end

local TabAimbot = Instance.new("TextButton")
local TabVis    = Instance.new("TextButton")
do  -- TabBar is only needed as parent; _c1/_c2 corners are one-shot
    local TabBar = Instance.new("Frame")
    TabBar.Size                   = UDim2.new(1, -16, 0, 26)
    TabBar.Position               = UDim2.new(0, 8, 0, 36)
    TabBar.BackgroundTransparency = 1
    TabBar.ClipsDescendants       = true
    TabBar.Parent                 = MainFrame

    TabAimbot.Size             = UDim2.new(0.5, -2, 1, 0)
    TabAimbot.Position         = UDim2.new(0, 0, 0, 0)
    TabAimbot.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    TabAimbot.Text             = "🎯  Aimbot"
    TabAimbot.TextColor3       = Color3.new(1, 1, 1)
    TabAimbot.Font             = Enum.Font.GothamBold
    TabAimbot.TextSize         = 11
    TabAimbot.BorderSizePixel  = 0
    TabAimbot.Parent           = TabBar
    do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 4) c.Parent = TabAimbot end

    TabVis.Size             = UDim2.new(0.5, -2, 1, 0)
    TabVis.Position         = UDim2.new(0.5, 2, 0, 0)
    TabVis.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    TabVis.Text             = "👁  Visualisation"
    TabVis.TextColor3       = Color3.fromRGB(180, 180, 180)
    TabVis.Font             = Enum.Font.GothamBold
    TabVis.TextSize         = 11
    TabVis.BorderSizePixel  = 0
    TabVis.Parent           = TabBar
    do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 4) c.Parent = TabVis end
end

local Indicator = Instance.new("Frame")
do  -- IndicatorBar is only needed as parent; _ic corner is one-shot
    local IndicatorBar = Instance.new("Frame")
    IndicatorBar.Size             = UDim2.new(1, -16, 0, 3)
    IndicatorBar.Position         = UDim2.new(0, 8, 0, 62)
    IndicatorBar.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    IndicatorBar.BorderSizePixel  = 0
    IndicatorBar.Parent           = MainFrame

    Indicator.Size             = UDim2.new(0.5, -2, 0, 3)
    Indicator.Position         = UDim2.new(0, 0, 0, 0)
    Indicator.BackgroundColor3 = Color3.fromRGB(255, 100, 100)
    Indicator.BorderSizePixel  = 0
    Indicator.Parent           = IndicatorBar
    do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 2) c.Parent = Indicator end
end

local Content = Instance.new("ScrollingFrame")
Content.Size                = UDim2.new(1, -16, 1, -73)
Content.Position            = UDim2.new(0, 8, 0, 69)
Content.BackgroundTransparency = 1
Content.ScrollBarThickness  = 8
Content.ScrollBarImageColor3 = Color3.fromRGB(160, 160, 160)
Content.CanvasSize          = UDim2.new(0, 0, 0, 0)
Content.AutomaticCanvasSize = Enum.AutomaticSize.Y
Content.Parent              = MainFrame
do local l = Instance.new("UIListLayout") l.SortOrder = Enum.SortOrder.LayoutOrder l.Padding = UDim.new(0, 4) l.Parent = Content end

-- Tracks which container Create* widgets are parented into.
-- CreateLabel() updates this so all subsequent widgets fall inside it.
local currentSection = Content

-- Forward-declared so the Vis-tab widget builders (inside the do block below)
-- can assign them and applySettingsToUI (defined later) can still call them.
local setEspTeamCheck, setEspType, setPlayerEsp, setEspText, setEspTeamColors

local VisContent = Instance.new("ScrollingFrame")
VisContent.Size                = UDim2.new(1, -16, 1, -73)
VisContent.Position            = UDim2.new(0, 8, 0, 69)
VisContent.BackgroundTransparency = 1
VisContent.ScrollBarThickness  = 8
VisContent.ScrollBarImageColor3 = Color3.fromRGB(160, 160, 160)
VisContent.CanvasSize          = UDim2.new(0, 0, 0, 0)
VisContent.AutomaticCanvasSize = Enum.AutomaticSize.Y
VisContent.Visible             = false
VisContent.Parent              = MainFrame
do
    local visSection = VisContent  -- current child target for vis widgets

    -- Mirror of CreateLabel but targeting VisContent instead of Content.
    local function CreateVisLabel(text, color)
        local container = Instance.new("Frame")
        container.Size                = UDim2.new(1, 0, 0, 0)
        container.AutomaticSize       = Enum.AutomaticSize.Y
        container.BackgroundTransparency = 1
        container.BorderSizePixel     = 0
        container.Parent              = VisContent

        local header = Instance.new("Frame")
        header.Size             = UDim2.new(1, 0, 0, 20)
        header.BackgroundColor3 = color or Color3.fromRGB(60, 60, 80)
        header.BorderSizePixel  = 0
        header.Parent           = container
        do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 4) c.Parent = header end

        local lbl = Instance.new("TextLabel")
        lbl.Text                = text
        lbl.TextColor3          = Color3.new(1, 1, 1)
        lbl.Font                = Enum.Font.GothamBold
        lbl.TextSize            = 10
        lbl.BackgroundTransparency = 1
        lbl.Size                = UDim2.new(1, -30, 1, 0)
        lbl.TextXAlignment      = Enum.TextXAlignment.Left
        lbl.Parent              = header

        local collapseBtn = Instance.new("TextButton")
        collapseBtn.Size             = UDim2.new(0, 22, 0, 14)
        collapseBtn.Position         = UDim2.new(1, -24, 0.5, -7)
        collapseBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
        collapseBtn.Text             = "▼"
        collapseBtn.TextColor3       = Color3.new(1, 1, 1)
        collapseBtn.Font             = Enum.Font.GothamBold
        collapseBtn.TextSize         = 8
        collapseBtn.BorderSizePixel  = 0
        collapseBtn.AutoButtonColor  = false
        collapseBtn.Parent           = header
        do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 3) c.Parent = collapseBtn end

        local childArea = Instance.new("Frame")
        childArea.Size                = UDim2.new(1, 0, 0, 0)
        childArea.AutomaticSize       = Enum.AutomaticSize.Y
        childArea.BackgroundTransparency = 1
        childArea.Position            = UDim2.new(0, 0, 0, 22)
        childArea.Parent              = container
        do local l = Instance.new("UIListLayout") l.SortOrder = Enum.SortOrder.LayoutOrder l.Padding = UDim.new(0, 4) l.Parent = childArea end

        local isOpen = true
        collapseBtn.MouseButton1Click:Connect(function()
            isOpen = not isOpen
            childArea.Visible = isOpen
            collapseBtn.Text  = isOpen and "▼" or "▶"
        end)

        visSection = childArea
    end

    -- ── UIListLayout for VisContent root ──────────────────────────────────────
    do local l = Instance.new("UIListLayout") l.SortOrder = Enum.SortOrder.LayoutOrder l.Padding = UDim.new(0, 4) l.Parent = VisContent end

    CreateVisLabel("  🔴  FOV SETTINGS",  Color3.fromRGB(80, 40, 40))
    CreateVisLabel("  👁️  ESP SETTINGS",  Color3.fromRGB(35, 55, 90))

    -- ── Helpers that parent into `visSection` (set by the last CreateVisLabel) ──
    local function CreateVisToggle(name, default, callback)
        local f = Instance.new("Frame")
        f.Size                = UDim2.new(1, 0, 0, 24)
        f.BackgroundTransparency = 1
        f.Parent              = visSection

        local lbl = Instance.new("TextLabel")
        lbl.Text              = name
        lbl.TextColor3        = Color3.new(1, 1, 1)
        lbl.Font              = Enum.Font.Gotham
        lbl.TextSize          = 11
        lbl.Size              = UDim2.new(0.7, 0, 1, 0)
        lbl.BackgroundTransparency = 1
        lbl.TextXAlignment    = Enum.TextXAlignment.Left
        lbl.Parent            = f

        local togBg = Instance.new("Frame")
        togBg.Size             = UDim2.new(0, 36, 0, 18)
        togBg.Position         = UDim2.new(1, -36, 0.5, -9)
        togBg.BackgroundColor3 = default and Color3.fromRGB(100, 200, 100) or Color3.fromRGB(70, 70, 70)
        togBg.BorderSizePixel  = 0
        togBg.Parent           = f
        do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(1, 0) c.Parent = togBg end

        local knob = Instance.new("Frame")
        knob.Size             = UDim2.new(0, 14, 0, 14)
        knob.AnchorPoint      = Vector2.new(0.5, 0.5)
        knob.Position         = default and UDim2.new(1, -9, 0.5, 0) or UDim2.new(0, 9, 0.5, 0)
        knob.BackgroundColor3 = Color3.new(1, 1, 1)
        knob.BorderSizePixel  = 0
        knob.Parent           = togBg
        do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(1, 0) c.Parent = knob end

        local state = default
        local function setState(v)
            state = v
            togBg.BackgroundColor3 = v and Color3.fromRGB(100, 200, 100) or Color3.fromRGB(70, 70, 70)
            knob.Position = v and UDim2.new(1, -9, 0.5, 0) or UDim2.new(0, 9, 0.5, 0)
            callback(v)
        end

        togBg.InputBegan:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch then
                setState(not state)
            end
        end)

        table.insert(uiResets, function() setState(default) end)
        return setState
    end

    local function CreateVisDropdown(name, options, default, callback)
        local f = Instance.new("Frame")
        f.Size                = UDim2.new(1, 0, 0, 24)
        f.BackgroundTransparency = 1
        f.ZIndex              = 5
        f.Parent              = visSection

        local lbl = Instance.new("TextLabel")
        lbl.Text              = name
        lbl.TextColor3        = Color3.new(1, 1, 1)
        lbl.Font              = Enum.Font.Gotham
        lbl.TextSize          = 11
        lbl.Size              = UDim2.new(0.45, 0, 1, 0)
        lbl.BackgroundTransparency = 1
        lbl.TextXAlignment    = Enum.TextXAlignment.Left
        lbl.Parent            = f

        local dropBtn = Instance.new("TextButton")
        dropBtn.Size             = UDim2.new(0, 100, 0, 20)
        dropBtn.Position         = UDim2.new(1, -100, 0.5, -10)
        dropBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
        dropBtn.Text             = default
        dropBtn.TextColor3       = Color3.new(1, 1, 1)
        dropBtn.Font             = Enum.Font.Gotham
        dropBtn.TextSize         = 11
        dropBtn.Parent           = f
        do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 4) c.Parent = dropBtn end

        local dropList = Instance.new("Frame")
        dropList.Size             = UDim2.new(0, 100, 0, 0)
        dropList.Position         = UDim2.new(1, -100, 1, 3)
        dropList.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
        dropList.BorderSizePixel  = 0
        dropList.Visible          = false
        dropList.ZIndex           = 10
        dropList.Parent           = f
        do local dll = Instance.new("UIListLayout")
           dll.SortOrder = Enum.SortOrder.LayoutOrder
           dll.Parent    = dropList end

        for _, option in ipairs(options) do
            local opt = Instance.new("TextButton")
            opt.Size                = UDim2.new(1, 0, 0, 22)
            opt.BackgroundTransparency = 1
            opt.Text                = option
            opt.TextColor3          = Color3.new(1, 1, 1)
            opt.Font                = Enum.Font.Gotham
            opt.TextSize            = 11
            opt.ZIndex              = 10
            opt.Parent              = dropList
            opt.MouseButton1Click:Connect(function()
                dropBtn.Text     = option
                dropList.Visible = false
                callback(option)
            end)
        end

        dropBtn.MouseButton1Click:Connect(function()
            dropList.Visible = not dropList.Visible
            dropList.Size    = dropList.Visible
                and UDim2.new(0, 100, 0, #options * 22)
                or  UDim2.new(0, 100, 0, 0)
        end)

        local function setOption(v)
            dropBtn.Text     = v
            dropList.Visible = false
            callback(v)
        end

        table.insert(uiResets, function()
            dropBtn.Text = default
            callback(default)
        end)

        return setOption
    end

    -- ── CreateVisSubLabel: collapsible sub-section nested inside the current
    -- visSection (vs CreateVisLabel which always parents to VisContent root).
    -- Returns the wrapper frame so callers can save/restore visSection manually.
    local function CreateVisSubLabel(text, color)
        local accentColor = color or Color3.fromRGB(50, 65, 100)

        local wrapper = Instance.new("Frame")
        wrapper.Size                = UDim2.new(1, 0, 0, 0)
        wrapper.AutomaticSize       = Enum.AutomaticSize.Y
        wrapper.BackgroundTransparency = 1
        wrapper.BorderSizePixel     = 0
        wrapper.Parent              = visSection

        local accentBar = Instance.new("Frame")
        accentBar.Size             = UDim2.new(0, 3, 1, 0)
        accentBar.BackgroundColor3 = accentColor
        accentBar.BorderSizePixel  = 0
        accentBar.Parent           = wrapper
        do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 2) c.Parent = accentBar end

        local inner = Instance.new("Frame")
        inner.Size                = UDim2.new(1, -8, 0, 0)
        inner.Position            = UDim2.new(0, 8, 0, 0)
        inner.AutomaticSize       = Enum.AutomaticSize.Y
        inner.BackgroundTransparency = 1
        inner.Parent              = wrapper

        local header = Instance.new("Frame")
        header.Size             = UDim2.new(1, 0, 0, 17)
        header.BackgroundColor3 = accentColor
        header.BackgroundTransparency = 0.35
        header.BorderSizePixel  = 0
        header.Parent           = inner
        do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 4) c.Parent = header end

        local lbl = Instance.new("TextLabel")
        lbl.Text                = text
        lbl.TextColor3          = Color3.fromRGB(220, 220, 220)
        lbl.Font                = Enum.Font.GothamBold
        lbl.TextSize            = 9
        lbl.BackgroundTransparency = 1
        lbl.Size                = UDim2.new(1, -26, 1, 0)
        lbl.Position            = UDim2.new(0, 6, 0, 0)
        lbl.TextXAlignment      = Enum.TextXAlignment.Left
        lbl.Parent              = header

        local collapseBtn = Instance.new("TextButton")
        collapseBtn.Size             = UDim2.new(0, 18, 0, 12)
        collapseBtn.Position         = UDim2.new(1, -20, 0.5, -6)
        collapseBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
        collapseBtn.BackgroundTransparency = 0.4
        collapseBtn.Text             = "▼"
        collapseBtn.TextColor3       = Color3.fromRGB(200, 200, 200)
        collapseBtn.Font             = Enum.Font.GothamBold
        collapseBtn.TextSize         = 7
        collapseBtn.BorderSizePixel  = 0
        collapseBtn.AutoButtonColor  = false
        collapseBtn.Parent           = header
        do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 3) c.Parent = collapseBtn end

        local childArea = Instance.new("Frame")
        childArea.Size                = UDim2.new(1, 0, 0, 0)
        childArea.AutomaticSize       = Enum.AutomaticSize.Y
        childArea.BackgroundTransparency = 1
        childArea.Position            = UDim2.new(0, 0, 0, 19)
        childArea.Parent              = inner
        do local l = Instance.new("UIListLayout")
           l.SortOrder = Enum.SortOrder.LayoutOrder
           l.Padding   = UDim.new(0, 3)
           l.Parent    = childArea end

        local isOpen = true
        collapseBtn.MouseButton1Click:Connect(function()
            isOpen = not isOpen
            childArea.Visible = isOpen
            collapseBtn.Text  = isOpen and "▼" or "▶"
        end)

        visSection = childArea
        return wrapper
    end

    -- ── CreateVisSubButtons: same as CreateVisSubLabel but no header at all.
    -- Just an indented accent-bar container that groups related vis widgets.
    local function CreateVisSubButtons(color)
        local accentColor = color or Color3.fromRGB(50, 65, 100)

        local wrapper = Instance.new("Frame")
        wrapper.Size                = UDim2.new(1, 0, 0, 0)
        wrapper.AutomaticSize       = Enum.AutomaticSize.Y
        wrapper.BackgroundTransparency = 1
        wrapper.BorderSizePixel     = 0
        wrapper.Parent              = visSection

        local accentBar = Instance.new("Frame")
        accentBar.Size             = UDim2.new(0, 3, 1, 0)
        accentBar.BackgroundColor3 = accentColor
        accentBar.BorderSizePixel  = 0
        accentBar.Parent           = wrapper
        do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 2) c.Parent = accentBar end

        local inner = Instance.new("Frame")
        inner.Size                = UDim2.new(1, -8, 0, 0)
        inner.Position            = UDim2.new(0, 8, 0, 0)
        inner.AutomaticSize       = Enum.AutomaticSize.Y
        inner.BackgroundTransparency = 1
        inner.Parent              = wrapper

        local childArea = Instance.new("Frame")
        childArea.Size                = UDim2.new(1, 0, 0, 0)
        childArea.AutomaticSize       = Enum.AutomaticSize.Y
        childArea.BackgroundTransparency = 1
        childArea.Parent              = inner
        do local l = Instance.new("UIListLayout")
           l.SortOrder = Enum.SortOrder.LayoutOrder
           l.Padding   = UDim.new(0, 3)
           l.Parent    = childArea end

        visSection = childArea
        return wrapper
    end

    -- ── ESP SETTINGS sub-sections ─────────────────────────────────────────────
    local espSection = visSection   -- save ESP SETTINGS childArea to return to it

    -- ── Players ESP ───────────────────────────────────────────────────────────
    CreateVisSubLabel("  👤  Players ESP", Color3.fromRGB(35, 70, 110))
    local playersEspSection = visSection   -- save Players ESP childArea

    -- "Enabled" is the player-specific sub-toggle. The master ESP toggle in
    -- GENERAL must also be ON for players to actually be rendered.
    setPlayerEsp = CreateVisToggle("Enabled", Defaults.PlayerEspEnabled, function(v)
        Settings.PlayerEspEnabled = v
    end)

    -- Team Check sits above Esp Types
    setEspTeamCheck = CreateVisToggle("ESP Team Check", Defaults.EspTeamCheck,
        function(v) Settings.EspTeamCheck = v end)

    -- Sub-buttons under Team Check: Uses Team Colors
    CreateVisSubButtons(Color3.fromRGB(35, 70, 110))

    setEspTeamColors = CreateVisToggle("Uses Team Colors", Defaults.EspTeamColors,
        function(v) Settings.EspTeamColors = v end)

    -- Return to Players ESP level for Esp Types and Text Settings
    visSection = playersEspSection

    -- Esp Types below Team Check block
    setEspType = CreateVisDropdown("Esp Types", {"Box", "Circle/Mark", "Charm"}, Defaults.EspType,
        function(v) Settings.EspType = v end)

    -- ── Text Settings (nested inside Players ESP) ─────────────────────────────
    CreateVisSubLabel("  🔤  Text Settings", Color3.fromRGB(50, 60, 100))

    setEspText = CreateVisToggle("Enabled", Defaults.EspTextEnabled, function(v)
        Settings.EspTextEnabled = v
    end)

    -- Return to Players ESP level then ESP level.
    visSection = playersEspSection

    -- ── Objects ESP (reserved, empty for now) ─────────────────────────────────
    visSection = espSection   -- return to ESP SETTINGS level before next sub-label
    CreateVisSubLabel("  📦  Objects ESP", Color3.fromRGB(60, 80, 55))
end

local function setActiveTab(isAimbot)
    Content.Visible    = isAimbot
    VisContent.Visible = not isAimbot

    TabAimbot.BackgroundColor3 = isAimbot
        and Color3.fromRGB(60, 60, 60) or Color3.fromRGB(45, 45, 45)
    TabAimbot.TextColor3 = isAimbot
        and Color3.new(1, 1, 1) or Color3.fromRGB(180, 180, 180)
    TabVis.BackgroundColor3 = not isAimbot
        and Color3.fromRGB(60, 60, 60) or Color3.fromRGB(45, 45, 45)
    TabVis.TextColor3 = not isAimbot
        and Color3.new(1, 1, 1) or Color3.fromRGB(180, 180, 180)

    Indicator.Position = isAimbot
        and UDim2.new(0, 0, 0, 0) or UDim2.new(0.5, 2, 0, 0)
end

TabAimbot.MouseButton1Click:Connect(function() setActiveTab(true)  end)
TabVis.MouseButton1Click:Connect(function()    setActiveTab(false) end)
setActiveTab(true)

-- ============================================================
-- [8] UI COMPONENT FACTORIES
-- ============================================================

-- Single shared InputChanged connection for all sliders (avoids N listeners)
local activeDragData = nil

UIS.InputChanged:Connect(function(input)
    if not activeDragData then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement
    and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local d   = activeDragData
    local pct = mclamp(
        (input.Position.X - d.track.AbsolutePosition.X) / d.track.AbsoluteSize.X, 0, 1)
    d.applyFn(d.min + (d.max - d.min) * pct)
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        activeDragData = nil
    end
end)

local function CreateLabel(text, color)
    -- ── Outer container (header + collapsible child area) ─────────────────────
    local container = Instance.new("Frame")
    container.Size                = UDim2.new(1, 0, 0, 0)
    container.AutomaticSize       = Enum.AutomaticSize.Y
    container.BackgroundTransparency = 1
    container.BorderSizePixel     = 0
    container.Parent              = Content  -- always a direct child of Content

    -- ── Header bar ────────────────────────────────────────────────────────────
    local header = Instance.new("Frame")
    header.Size             = UDim2.new(1, 0, 0, 20)
    header.BackgroundColor3 = color or Color3.fromRGB(60, 60, 80)
    header.BorderSizePixel  = 0
    header.Parent           = container
    local hc = Instance.new("UICorner") hc.CornerRadius = UDim.new(0, 4) hc.Parent = header

    local lbl = Instance.new("TextLabel")
    lbl.Text                = text
    lbl.TextColor3          = Color3.new(1, 1, 1)
    lbl.Font                = Enum.Font.GothamBold
    lbl.TextSize            = 10
    lbl.BackgroundTransparency = 1
    lbl.Size                = UDim2.new(1, -30, 1, 0)
    lbl.Position            = UDim2.new(0, 0, 0, 0)
    lbl.TextXAlignment      = Enum.TextXAlignment.Left
    lbl.Parent              = header

    -- ── Collapse / expand button (right side of header) ───────────────────────
    local collapseBtn = Instance.new("TextButton")
    collapseBtn.Size             = UDim2.new(0, 22, 0, 14)
    collapseBtn.Position         = UDim2.new(1, -24, 0.5, -7)
    collapseBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
    collapseBtn.Text             = "▼"
    collapseBtn.TextColor3       = Color3.new(1, 1, 1)
    collapseBtn.Font             = Enum.Font.GothamBold
    collapseBtn.TextSize         = 8
    collapseBtn.BorderSizePixel  = 0
    collapseBtn.AutoButtonColor  = false
    collapseBtn.Parent           = header
    local cbc = Instance.new("UICorner") cbc.CornerRadius = UDim.new(0, 3) cbc.Parent = collapseBtn

    -- ── Children area ─────────────────────────────────────────────────────────
    local childArea = Instance.new("Frame")
    childArea.Size                = UDim2.new(1, 0, 0, 0)
    childArea.AutomaticSize       = Enum.AutomaticSize.Y
    childArea.BackgroundTransparency = 1
    childArea.Position            = UDim2.new(0, 0, 0, 22)  -- 2px gap below header
    childArea.Parent              = container
    local cll = Instance.new("UIListLayout")
    cll.SortOrder = Enum.SortOrder.LayoutOrder
    cll.Padding   = UDim.new(0, 4)
    cll.Parent    = childArea

    -- ── Toggle logic ──────────────────────────────────────────────────────────
    local isOpen = true
    collapseBtn.MouseButton1Click:Connect(function()
        isOpen = not isOpen
        childArea.Visible  = isOpen
        collapseBtn.Text   = isOpen and "▼" or "▶"
    end)

    -- All subsequent Create* widgets go inside this section's childArea
    currentSection = childArea

    return container
end

-- CreateSubLabel: a smaller collapsible sub-container that nests inside
-- the current section (i.e. a parent CreateLabel's childArea).
-- Visual differences from CreateLabel:
--   • Indented 8 px from the left with a coloured 3 px accent bar
--   • Header height 17 px (vs 20 px) and font size 9 (vs 10)
--   • Slightly translucent background so it reads as subordinate
--   • Sets currentSection to its own childArea so widgets appended
--     immediately after live inside this sub-container
local function CreateSubLabel(text, color)
    local accentColor = color or Color3.fromRGB(70, 70, 100)

    -- ── Outer wrapper (indent + accent bar + content) ─────────────────────────
    local wrapper = Instance.new("Frame")
    wrapper.Size                = UDim2.new(1, 0, 0, 0)
    wrapper.AutomaticSize       = Enum.AutomaticSize.Y
    wrapper.BackgroundTransparency = 1
    wrapper.BorderSizePixel     = 0
    wrapper.Parent              = currentSection  -- child of the parent section

    -- Coloured 3 px vertical accent bar on the left edge
    local accentBar = Instance.new("Frame")
    accentBar.Size             = UDim2.new(0, 3, 1, 0)
    accentBar.Position         = UDim2.new(0, 0, 0, 0)
    accentBar.BackgroundColor3 = accentColor
    accentBar.BorderSizePixel  = 0
    accentBar.Parent           = wrapper
    do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 2) c.Parent = accentBar end

    -- Inner container shifted 8 px right (accent bar + gap)
    local inner = Instance.new("Frame")
    inner.Size                = UDim2.new(1, -8, 0, 0)
    inner.Position            = UDim2.new(0, 8, 0, 0)
    inner.AutomaticSize       = Enum.AutomaticSize.Y
    inner.BackgroundTransparency = 1
    inner.BorderSizePixel     = 0
    inner.Parent              = wrapper

    -- ── Sub-header ────────────────────────────────────────────────────────────
    local header = Instance.new("Frame")
    header.Size             = UDim2.new(1, 0, 0, 17)
    header.BackgroundColor3 = accentColor
    header.BackgroundTransparency = 0.35
    header.BorderSizePixel  = 0
    header.Parent           = inner
    do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 4) c.Parent = header end

    local lbl = Instance.new("TextLabel")
    lbl.Text                = text
    lbl.TextColor3          = Color3.fromRGB(220, 220, 220)
    lbl.Font                = Enum.Font.GothamBold
    lbl.TextSize            = 9
    lbl.BackgroundTransparency = 1
    lbl.Size                = UDim2.new(1, -26, 1, 0)
    lbl.Position            = UDim2.new(0, 6, 0, 0)
    lbl.TextXAlignment      = Enum.TextXAlignment.Left
    lbl.Parent              = header

    -- Collapse button
    local collapseBtn = Instance.new("TextButton")
    collapseBtn.Size             = UDim2.new(0, 18, 0, 12)
    collapseBtn.Position         = UDim2.new(1, -20, 0.5, -6)
    collapseBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
    collapseBtn.BackgroundTransparency = 0.4
    collapseBtn.Text             = "▼"
    collapseBtn.TextColor3       = Color3.fromRGB(200, 200, 200)
    collapseBtn.Font             = Enum.Font.GothamBold
    collapseBtn.TextSize         = 7
    collapseBtn.BorderSizePixel  = 0
    collapseBtn.AutoButtonColor  = false
    collapseBtn.Parent           = header
    do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 3) c.Parent = collapseBtn end

    -- ── Children area ─────────────────────────────────────────────────────────
    local childArea = Instance.new("Frame")
    childArea.Size                = UDim2.new(1, 0, 0, 0)
    childArea.AutomaticSize       = Enum.AutomaticSize.Y
    childArea.BackgroundTransparency = 1
    childArea.Position            = UDim2.new(0, 0, 0, 19)  -- 2 px gap below sub-header
    childArea.Parent              = inner
    local cll = Instance.new("UIListLayout")
    cll.SortOrder = Enum.SortOrder.LayoutOrder
    cll.Padding   = UDim.new(0, 3)
    cll.Parent    = childArea

    -- ── Toggle logic ──────────────────────────────────────────────────────────
    local isOpen = true
    collapseBtn.MouseButton1Click:Connect(function()
        isOpen = not isOpen
        childArea.Visible = isOpen
        collapseBtn.Text  = isOpen and "▼" or "▶"
    end)

    -- Redirect subsequent Create* widgets into this sub-container
    currentSection = childArea

    return wrapper
end

-- CreateSubButtons: a headerless indented container — like CreateSubLabel but
-- with no title bar or collapse button. Used to visually group a small set of
-- related items under a parent toggle without adding another labelled tier.
-- Sets currentSection to its own childArea so subsequent Create* calls land
-- inside it; caller must restore currentSection when done.
local function CreateSubButtons(color)
    local accentColor = color or Color3.fromRGB(70, 70, 100)

    local wrapper = Instance.new("Frame")
    wrapper.Size                = UDim2.new(1, 0, 0, 0)
    wrapper.AutomaticSize       = Enum.AutomaticSize.Y
    wrapper.BackgroundTransparency = 1
    wrapper.BorderSizePixel     = 0
    wrapper.Parent              = currentSection

    local accentBar = Instance.new("Frame")
    accentBar.Size             = UDim2.new(0, 3, 1, 0)
    accentBar.BackgroundColor3 = accentColor
    accentBar.BorderSizePixel  = 0
    accentBar.Parent           = wrapper
    do local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 2) c.Parent = accentBar end

    local inner = Instance.new("Frame")
    inner.Size                = UDim2.new(1, -8, 0, 0)
    inner.Position            = UDim2.new(0, 8, 0, 0)
    inner.AutomaticSize       = Enum.AutomaticSize.Y
    inner.BackgroundTransparency = 1
    inner.Parent              = wrapper

    local childArea = Instance.new("Frame")
    childArea.Size                = UDim2.new(1, 0, 0, 0)
    childArea.AutomaticSize       = Enum.AutomaticSize.Y
    childArea.BackgroundTransparency = 1
    childArea.Parent              = inner
    local cll = Instance.new("UIListLayout")
    cll.SortOrder = Enum.SortOrder.LayoutOrder
    cll.Padding   = UDim.new(0, 3)
    cll.Parent    = childArea

    currentSection = childArea
    return wrapper
end

local function CreateToggle(name, default, callback)
    local f = Instance.new("Frame")
    f.Size                = UDim2.new(1, 0, 0, 24)
    f.BackgroundTransparency = 1
    f.Parent              = currentSection

    local lbl = Instance.new("TextLabel")
    lbl.Text              = name
    lbl.TextColor3        = Color3.new(1, 1, 1)
    lbl.Font              = Enum.Font.Gotham
    lbl.TextSize          = 11
    lbl.Size              = UDim2.new(0.6, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextXAlignment    = Enum.TextXAlignment.Left
    lbl.Parent            = f

    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, 44, 0, 18)
    btn.Position         = UDim2.new(1, -44, 0.5, -9)
    btn.BackgroundColor3 = default and Color3.fromRGB(50, 205, 50) or Color3.fromRGB(80, 80, 80)
    btn.Text             = default and "ON" or "OFF"
    btn.TextColor3       = Color3.new(1, 1, 1)
    btn.Font             = Enum.Font.GothamBold
    btn.TextSize         = 10
    btn.Parent           = f
    local bc = Instance.new("UICorner") bc.CornerRadius = UDim.new(0, 4) bc.Parent = btn

    local state = default
    btn.MouseButton1Click:Connect(function()
        state = not state
        btn.Text             = state and "ON" or "OFF"
        btn.BackgroundColor3 = state
            and Color3.fromRGB(50, 205, 50) or Color3.fromRGB(80, 80, 80)
        callback(state)
    end)

    -- setState: syncs the widget visuals AND fires the callback.
    -- Used by applySettingsToUI() after a save-file load.
    local function setState(v)
        state                = v
        btn.Text             = v and "ON" or "OFF"
        btn.BackgroundColor3 = v
            and Color3.fromRGB(50, 205, 50) or Color3.fromRGB(80, 80, 80)
        callback(v)
    end

    table.insert(uiResets, function()
        state                = default
        btn.Text             = default and "ON" or "OFF"
        btn.BackgroundColor3 = default
            and Color3.fromRGB(50, 205, 50) or Color3.fromRGB(80, 80, 80)
        callback(default)
    end)

    return f, setState
end

-- FIX: CreateSlider now returns three values: (frame, setLocked, setValue).
-- The new `setValue` closure lets sibling sliders cross-update each other's UI
-- when one clamps the other (e.g. Min HP pushing Max HP up), preventing the
-- visual drift that occurred in the original where Settings was updated in
-- memory but the companion slider's fill bar and label stayed stale.
local function CreateSlider(name, min, max, default, callback)
    local f = Instance.new("Frame")
    f.Size                = UDim2.new(1, 0, 0, 54)
    f.BackgroundTransparency = 1
    f.Parent              = currentSection

    local lbl = Instance.new("TextLabel")
    lbl.Name              = "TitleLabel"
    lbl.Text              = name .. ": " .. tostring(default)
    lbl.TextColor3        = Color3.new(1, 1, 1)
    lbl.Font              = Enum.Font.Gotham
    lbl.TextSize          = 11
    lbl.Size              = UDim2.new(1, -50, 0, 14)
    lbl.Position          = UDim2.new(0, 0, 0, 8)
    lbl.BackgroundTransparency = 1
    lbl.TextXAlignment    = Enum.TextXAlignment.Left
    lbl.TextTruncate      = Enum.TextTruncate.AtEnd
    lbl.Parent            = f

    local tb = Instance.new("TextBox")
    tb.Size             = UDim2.new(0, 46, 0, 14)
    tb.Position         = UDim2.new(1, -46, 0, 8)
    tb.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    tb.BorderSizePixel  = 0
    tb.Text             = tostring(default)
    tb.TextColor3       = Color3.new(1, 1, 1)
    tb.Font             = Enum.Font.Gotham
    tb.TextSize         = 10
    tb.ClearTextOnFocus = true
    tb.Parent           = f
    local tbc = Instance.new("UICorner") tbc.CornerRadius = UDim.new(0, 3) tbc.Parent = tb

    local track = Instance.new("TextButton")
    track.Text             = ""
    track.Size             = UDim2.new(1, 0, 0, 16)
    track.Position         = UDim2.new(0, 0, 1, -20)
    track.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    track.AutoButtonColor  = false
    track.ClipsDescendants = false
    track.Parent           = f
    local trc = Instance.new("UICorner") trc.CornerRadius = UDim.new(0, 4) trc.Parent = track

    local fill = Instance.new("Frame")
    fill.Size             = UDim2.new((default - min) / (max - min), 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(255, 100, 100)
    fill.Parent           = track
    local fc = Instance.new("UICorner") fc.CornerRadius = UDim.new(0, 4) fc.Parent = fill

    local knob = Instance.new("Frame")
    knob.Size             = UDim2.new(0, 14, 0, 14)
    knob.AnchorPoint      = Vector2.new(0.5, 0.5)
    knob.Position         = UDim2.new((default - min) / (max - min), 0, 0.5, 0)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel  = 0
    knob.ZIndex           = 3
    knob.Parent           = track
    local kc = Instance.new("UICorner") kc.CornerRadius = UDim.new(1, 0) kc.Parent = knob

    local knobDot = Instance.new("Frame")
    knobDot.Size             = UDim2.new(0, 6, 0, 6)
    knobDot.AnchorPoint      = Vector2.new(0.5, 0.5)
    knobDot.Position         = UDim2.new(0.5, 0, 0.5, 0)
    knobDot.BackgroundColor3 = Color3.fromRGB(255, 100, 100)
    knobDot.BorderSizePixel  = 0
    knobDot.ZIndex           = 4
    knobDot.Parent           = knob
    local kdc = Instance.new("UICorner") kdc.CornerRadius = UDim.new(1, 0) kdc.Parent = knobDot

    local locked = false

    local function applyValue(value)
        if locked then return end
        value = mclamp(mfloor(value * 100 + 0.5) / 100, min, max)
        local pct     = (value - min) / (max - min)
        fill.Size     = UDim2.new(pct, 0, 1, 0)
        knob.Position = UDim2.new(pct, 0, 0.5, 0)
        lbl.Text      = name .. ": " .. tostring(value)
        tb.Text       = tostring(value)
        callback(value)
    end

    local function setLocked(isLocked)
        locked = isLocked
        local dimColor    = Color3.fromRGB(100, 100, 100)
        local activeColor = Color3.fromRGB(255, 100, 100)
        local trackColor  = Color3.fromRGB(60, 60, 60)
        track.BackgroundColor3   = isLocked and dimColor or trackColor
        fill.BackgroundColor3    = isLocked and dimColor or activeColor
        knob.BackgroundColor3    = isLocked and dimColor or Color3.fromRGB(255, 255, 255)
        knobDot.BackgroundColor3 = isLocked and dimColor or activeColor
        lbl.TextColor3           = isLocked and dimColor or Color3.new(1, 1, 1)
        tb.TextColor3            = isLocked and dimColor or Color3.new(1, 1, 1)
        tb.TextEditable          = not isLocked
    end

    -- FIX: Exposed setValue bypasses the `locked` guard so sibling sliders can
    -- push a new visual value during cross-clamping without needing to unlock
    -- the companion slider first.  The caller (section [10]) is responsible for
    -- only calling this when appropriate (i.e. when Health Check is active).
    local function setValue(value)
        value = mclamp(mfloor(value * 100 + 0.5) / 100, min, max)
        local pct = (value - min) / (max - min)
        fill.Size     = UDim2.new(pct, 0, 1, 0)
        knob.Position = UDim2.new(pct, 0, 0.5, 0)
        lbl.Text      = name .. ": " .. tostring(value)
        tb.Text       = tostring(value)
    end

    track.InputBegan:Connect(function(input)
        if locked then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            activeDragData = { track = track, min = min, max = max, applyFn = applyValue }
            local pct = mclamp(
                (input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
            applyValue(min + (max - min) * pct)
        end
    end)

    tb.FocusLost:Connect(function()
        if locked then
            tb.Text = lbl.Text:match(": (.+)$") or tostring(default)
            return
        end
        local typed = tonumber(tb.Text)
        if typed then
            applyValue(typed)
        else
            tb.Text = lbl.Text:match(": (.+)$") or tostring(default)
        end
    end)

    table.insert(uiResets, function()
        locked = false
        setLocked(false)
        applyValue(default)
    end)

    return f, setLocked, setValue   -- three return values (setValue is new)
end

local function CreateDropdown(name, options, default, callback)
    local f = Instance.new("Frame")
    f.Size                = UDim2.new(1, 0, 0, 24)
    f.BackgroundTransparency = 1
    f.ZIndex              = 5
    f.Parent              = currentSection

    local lbl = Instance.new("TextLabel")
    lbl.Text              = name
    lbl.TextColor3        = Color3.new(1, 1, 1)
    lbl.Font              = Enum.Font.Gotham
    lbl.TextSize          = 11
    lbl.Size              = UDim2.new(0.45, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextXAlignment    = Enum.TextXAlignment.Left
    lbl.Parent            = f

    local dropBtn = Instance.new("TextButton")
    dropBtn.Size             = UDim2.new(0, 100, 0, 20)
    dropBtn.Position         = UDim2.new(1, -100, 0.5, -10)
    dropBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    dropBtn.Text             = default
    dropBtn.TextColor3       = Color3.new(1, 1, 1)
    dropBtn.Font             = Enum.Font.Gotham
    dropBtn.TextSize         = 11
    dropBtn.Parent           = f
    local dc = Instance.new("UICorner") dc.CornerRadius = UDim.new(0, 4) dc.Parent = dropBtn

    local dropList = Instance.new("Frame")
    dropList.Size             = UDim2.new(0, 100, 0, 0)
    dropList.Position         = UDim2.new(1, -100, 1, 3)
    dropList.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    dropList.BorderSizePixel  = 0
    dropList.Visible          = false
    dropList.ZIndex           = 10
    dropList.Parent           = f
    local dll = Instance.new("UIListLayout")
    dll.SortOrder = Enum.SortOrder.LayoutOrder
    dll.Parent    = dropList

    for _, option in ipairs(options) do
        local opt = Instance.new("TextButton")
        opt.Size                = UDim2.new(1, 0, 0, 22)
        opt.BackgroundTransparency = 1
        opt.Text                = option
        opt.TextColor3          = Color3.new(1, 1, 1)
        opt.Font                = Enum.Font.Gotham
        opt.TextSize            = 11
        opt.ZIndex              = 10
        opt.Parent              = dropList
        opt.MouseButton1Click:Connect(function()
            dropBtn.Text     = option
            dropList.Visible = false
            callback(option)
        end)
    end

    dropBtn.MouseButton1Click:Connect(function()
        dropList.Visible = not dropList.Visible
        dropList.Size    = dropList.Visible
            and UDim2.new(0, 100, 0, #options * 22)
            or  UDim2.new(0, 100, 0, 0)
    end)

    -- setOption: syncs the button label AND fires the callback.
    -- Used by applySettingsToUI() after a save-file load.
    local function setOption(v)
        dropBtn.Text     = v
        dropList.Visible = false
        callback(v)
    end

    table.insert(uiResets, function()
        dropBtn.Text = default
        callback(default)
    end)

    return dropBtn, setOption
end

-- ── Multi-select dropdown ─────────────────────────────────────────────────────
-- Constants inlined inside CreateMultiDropdown to avoid 3 chunk-level slots.
local function CreateMultiDropdown(name, getOptions, selected, onChange)
    local LABEL_H     = 18
    local BTN_H       = 26
    local GAP         = 4
    local ROW_H       = 24   -- was ROW_H
    local MAX_VIS     = 7    -- was MAX_VIS
    local COLLAPSED_H = LABEL_H + GAP + BTN_H   -- 48 px collapsed

    local f = Instance.new("Frame")
    f.Size                = UDim2.new(1, 0, 0, COLLAPSED_H)
    f.BackgroundTransparency = 1
    f.ClipsDescendants    = false
    f.ZIndex              = 6
    f.Parent              = currentSection

    local lbl = Instance.new("TextLabel")
    lbl.Text              = name
    lbl.TextColor3        = Color3.new(1, 1, 1)
    lbl.Font              = Enum.Font.Gotham
    lbl.TextSize          = 11
    lbl.Size              = UDim2.new(1, 0, 0, LABEL_H)
    lbl.Position          = UDim2.new(0, 2, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextXAlignment    = Enum.TextXAlignment.Left
    lbl.Parent            = f

    local dropBtn = Instance.new("TextButton")
    dropBtn.Size             = UDim2.new(1, 0, 0, BTN_H)
    dropBtn.Position         = UDim2.new(0, 0, 0, LABEL_H + GAP)
    dropBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
    dropBtn.BorderSizePixel  = 0
    dropBtn.Font             = Enum.Font.Gotham
    dropBtn.TextSize         = 11
    dropBtn.TextColor3       = Color3.new(1, 1, 1)
    dropBtn.TextXAlignment   = Enum.TextXAlignment.Left
    dropBtn.Text             = "  ▾  None selected"
    dropBtn.ZIndex           = 6
    dropBtn.Parent           = f
    local dbc = Instance.new("UICorner") dbc.CornerRadius = UDim.new(0,4) dbc.Parent = dropBtn

    local LIST_TOP = LABEL_H + GAP + BTN_H + 3
    local listFrame = Instance.new("ScrollingFrame")
    listFrame.Size                = UDim2.new(1, 0, 0, 0)
    listFrame.Position            = UDim2.new(0, 0, 0, LIST_TOP)
    listFrame.BackgroundColor3    = Color3.fromRGB(38, 38, 42)
    listFrame.BorderSizePixel     = 0
    listFrame.ScrollBarThickness  = 3
    listFrame.ScrollBarImageColor3 = Color3.fromRGB(120,120,120)
    listFrame.CanvasSize          = UDim2.new(0, 0, 0, 0)
    listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    listFrame.Visible             = false
    listFrame.ZIndex              = 20
    listFrame.ClipsDescendants    = true
    listFrame.Parent              = f
    local fll = Instance.new("UIListLayout")
    fll.SortOrder = Enum.SortOrder.LayoutOrder
    fll.Parent    = listFrame
    local llc = Instance.new("UICorner") llc.CornerRadius = UDim.new(0,4) llc.Parent = listFrame

    local clearBtn = Instance.new("TextButton")
    clearBtn.Size             = UDim2.new(1, 0, 0, ROW_H)
    clearBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 40)
    clearBtn.BorderSizePixel  = 0
    clearBtn.Text             = "✕  Clear All"
    clearBtn.TextColor3       = Color3.fromRGB(255, 130, 130)
    clearBtn.Font             = Enum.Font.GothamBold
    clearBtn.TextSize         = 10
    clearBtn.ZIndex           = 21
    clearBtn.LayoutOrder      = 9999
    clearBtn.Parent           = listFrame

    local function refreshButtonLabel()
        local count = 0
        local names = {}
        for k in pairs(selected) do
            count = count + 1
            names[#names+1] = k
        end
        table.sort(names)
        if count == 0 then
            dropBtn.Text = "  ▾  None selected"
        elseif count == 1 then
            dropBtn.Text = "  ▾  " .. names[1]
        else
            dropBtn.Text = "  ▾  " .. count .. " teams selected"
        end
    end

    local rowButtons = {}

    -- FIX: Safe two-pass destruction of old option rows.
    -- Setting values to nil while iterating with pairs() is undefined behaviour
    -- in standard Lua (can silently skip entries); collect keys first, then destroy.
    local function buildRows(options)
        local toRemove = {}
        for teamName in pairs(rowButtons) do
            toRemove[#toRemove + 1] = teamName
        end
        for _, teamName in ipairs(toRemove) do
            rowButtons[teamName]:Destroy()
            rowButtons[teamName] = nil
        end

        for idx, teamName in ipairs(options) do
            local isChecked = selected[teamName] == true

            local row = Instance.new("TextButton")
            row.Size                = UDim2.new(1, 0, 0, ROW_H)
            row.BackgroundColor3    = isChecked
                and Color3.fromRGB(50, 120, 50) or Color3.fromRGB(50, 50, 55)
            row.BorderSizePixel     = 0
            row.Text                = (isChecked and "  ✔  " or "      ") .. teamName
            row.TextColor3          = Color3.new(1, 1, 1)
            row.Font                = Enum.Font.Gotham
            row.TextSize            = 11
            row.TextXAlignment      = Enum.TextXAlignment.Left
            row.ZIndex              = 21
            row.LayoutOrder         = idx
            row.Parent              = listFrame

            -- FIX: Row toggle now uses the same checked colours and text prefix
            -- that buildRows uses.  The original used a different orange colour
            -- (238, 75, 43) and dropped the ✔ prefix on toggle, creating a
            -- visual mismatch between freshly-built rows and post-click state.
            row.MouseButton1Click:Connect(function()
                if selected[teamName] then
                    selected[teamName] = nil
                    row.Text             = "      " .. teamName
                    row.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
                else
                    selected[teamName] = true
                    row.Text             = "  ✔  " .. teamName
                    row.BackgroundColor3 = Color3.fromRGB(50, 120, 50)
                end
                refreshButtonLabel()
                onChange(selected)
            end)

            rowButtons[teamName] = row
        end
    end

    -- FIX: table.clear() is faster and cleaner than iterating to nil each key.
    clearBtn.MouseButton1Click:Connect(function()
        table.clear(selected)
        for teamName, row in pairs(rowButtons) do
            row.Text             = "      " .. teamName
            row.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
        end
        refreshButtonLabel()
        onChange(selected)
    end)

    local isOpen = false
    dropBtn.MouseButton1Click:Connect(function()
        isOpen = not isOpen
        if isOpen then
            local opts = getOptions()
            buildRows(opts)
            local visibleRows = mmin(#opts, MAX_VIS)
            listFrame.Size    = UDim2.new(1, 0, 0, (visibleRows + 1) * ROW_H)
            listFrame.Visible = true
            f.Size = UDim2.new(1, 0, 0, LIST_TOP + listFrame.AbsoluteSize.Y + 3)
        else
            listFrame.Visible = false
            f.Size = UDim2.new(1, 0, 0, COLLAPSED_H)
        end
        dropBtn.Text = isOpen
            and dropBtn.Text:gsub("▾", "▴")
            or  dropBtn.Text:gsub("▴", "▾")
    end)

    local function resetFn()
        table.clear(selected)
        -- Use teamName directly from rowButtons key — more reliable than
        -- attempting to parse or strip the text prefix from row.Text.
        for teamName, row in pairs(rowButtons) do
            row.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
            row.Text             = "      " .. teamName
        end
        refreshButtonLabel()
        isOpen = false
        listFrame.Visible = false
        f.Size = UDim2.new(1, 0, 0, COLLAPSED_H)
        onChange(selected)
    end
    table.insert(uiResets, resetFn)

    buildRows(getOptions())
    refreshButtonLabel()

    return f, resetFn
end

local legitSectionFrames = {}

local function setLegitSectionVisible(visible)
    for _, frame in ipairs(legitSectionFrames) do
        frame.Visible = visible
    end
end

-- CreateLegitLabel creates the collapsible section container for Legit settings
-- and registers the whole container in legitSectionFrames so the Mode dropdown
-- can hide/show the entire block at once.
local function CreateLegitSlider(name, min, max, default, callback)
    local f, lockFn, setFn = CreateSlider(name, min, max, default, callback)
    return f, lockFn, setFn
end

local function CreateLegitLabel(text, color)
    local container = CreateLabel(text, color)
    table.insert(legitSectionFrames, container)
end

-- ============================================================
-- [10] POPULATE UI
-- ============================================================
-- Forward-declare so closures built in this section can reference them.
-- The actual bodies are assigned in [12] after drawing objects exist.
local startAimbot, stopAimbot
local startEsp,    stopEsp

CreateLabel("  ⚙  GENERAL", Color3.fromRGB(45, 45, 70))
local setEnabled = (select(2, CreateToggle("Aimbot", Defaults.Enabled, function(v)
    Settings.Enabled = v
    if v then startAimbot() else stopAimbot() end
end)))
local setEsp = (select(2, CreateToggle("ESP", Defaults.EspEnabled, function(v)
    Settings.EspEnabled = v
    if v then startEsp() else stopEsp() end
end)))
local setWallCheck = (select(2, CreateToggle("Wall Check", Defaults.WallCheck, function(v)
    Settings.WallCheck = v
end)))
local setTeamCheck = (select(2, CreateToggle("Team Check", Defaults.TeamCheck, function(v) Settings.TeamCheck = v end)))

-- Forward-declare sub-label wrappers so toggle callbacks can reference them
-- before the sub-labels are created (they are created right after the toggles).
local predSubWrapper
local hcSubWrapper

local setPrediction = (select(2, CreateToggle("Prediction", Defaults.Prediction, function(v)
    Settings.Prediction = v
    if predSubWrapper then predSubWrapper.Visible = v end
end)))

-- Save GENERAL's childArea so we can return to it after each sub-label.
local generalSection = currentSection

-- ── Prediction sub-buttons (shows only while Prediction is ON) ───────────────
predSubWrapper = CreateSubButtons(Color3.fromRGB(55, 80, 130))
predSubWrapper.Visible = Defaults.Prediction

local predBiasFrame, lockPredBias, setPredBias = CreateSlider("Pred Bias", 0, 2, Defaults.PredictionFactor,
    function(v) Settings.PredictionFactor = v end)

local adaptiveFrame, setAdaptive = CreateToggle("Adaptive Prediction", Defaults.AdaptivePrediction, function(v)
    Settings.AdaptivePrediction = v
    lockPredBias(v)
end)

lockPredBias(Defaults.AdaptivePrediction)

-- Return to GENERAL level for the next top-level item.
currentSection = generalSection

-- ── Health Check (toggle + slider sub-label, both in GENERAL) ────────────────
-- Forward-declare setters so the toggle callback and slider callbacks can
-- reference each other regardless of creation order.
local setHealthMinUI, setHealthMaxUI
local healthMinFrame, lockHealthMin
local healthMaxFrame, lockHealthMax

local setHealthCheck = (select(2, CreateToggle("Health Check", Defaults.HealthCheckEnabled, function(v)
    Settings.HealthCheckEnabled = v
    lockHealthMin(not v)
    lockHealthMax(not v)
    if hcSubWrapper then hcSubWrapper.Visible = v end
    currentTarget = nil
    resetSpring()
    resetPrediction()
end)))

-- ── HP Range sub-buttons (shows only while Health Check is ON) ───────────────
hcSubWrapper = CreateSubButtons(Color3.fromRGB(100, 35, 35))
hcSubWrapper.Visible = Defaults.HealthCheckEnabled

healthMinFrame, lockHealthMin, setHealthMinUI = CreateSlider("Min HP %", 0, 100, Defaults.HealthMinHP,
    function(v)
        Settings.HealthMinHP = v
        if Settings.HealthMaxHP < v then
            Settings.HealthMaxHP = v
            if setHealthMaxUI then setHealthMaxUI(v) end
        end
    end)

healthMaxFrame, lockHealthMax, setHealthMaxUI = CreateSlider("Max HP %", 0, 100, Defaults.HealthMaxHP,
    function(v)
        Settings.HealthMaxHP = v
        if Settings.HealthMinHP > v then
            Settings.HealthMinHP = v
            if setHealthMinUI then setHealthMinUI(v) end
        end
    end)

-- Start with sliders locked (feature is OFF by default)
lockHealthMin(true)
lockHealthMax(true)

-- Return to GENERAL level for Target Part / Mode.
currentSection = generalSection

-- TargetPart dropdown: clear targetPartCache directly rather than polling
local setTargetPart = (select(2, CreateDropdown("Target Part", {"Head","Torso","Random"}, Defaults.TargetPart,
    function(v)
        Settings.TargetPart = v
        clearTargetPartCache()
    end)))

local setMode = (select(2, CreateDropdown("Mode", {"Blatant","Legit"}, Defaults.Mode, function(v)
    Settings.Mode = v
    setLegitSectionVisible(v == "Legit")
    currentTarget = nil
    isReacting    = false
end)))

CreateLabel("  ⚙️  GENERAL SETTINGS", Color3.fromRGB(55, 55, 85))
local setFOV        = (select(3, CreateSlider("FOV Radius",   10,  500, Defaults.FOV,        function(v) Settings.FOV         = v end)))
local setMaxDist    = (select(3, CreateSlider("Max Distance", 10,  500, Defaults.MaxDistance, function(v) Settings.MaxDistance = v end)))
local setSmoothness = (select(3, CreateSlider("Smoothness", 0.05,    1, Defaults.Smoothness,  function(v) Settings.Smoothness  = v end)))

-- ── Team Whitelist ────────────────────────────────────────────────────────────
CreateLabel("  🛡️  ALLY WHITELIST", Color3.fromRGB(35, 60, 100))

local TeamsService = game:GetService("Teams")

CreateMultiDropdown(
    "Whitelisted Teams",
    function()
        local list = {}
        for _, team in ipairs(TeamsService:GetTeams()) do
            list[#list + 1] = team.Name
        end
        table.sort(list)
        return list
    end,
    Settings.WhitelistedTeams,
    function(newSet)
        currentTarget = nil
        resetSpring()
        resetPrediction()
    end
)

CreateLegitLabel("  🟢  LEGIT SETTINGS", Color3.fromRGB(30, 90, 50))
local setMinReact  = (select(3, CreateLegitSlider("Min React (ms)",  100, 500, Defaults.MinReactionTime  * 1000, function(v) Settings.MinReactionTime  = v / 1000 end)))
local setMaxReact  = (select(3, CreateLegitSlider("Max React (ms)",  100, 500, Defaults.MaxReactionTime  * 1000, function(v) Settings.MaxReactionTime  = v / 1000 end)))
local setMeanReact = (select(3, CreateLegitSlider("Mean React (ms)", 100, 500, Defaults.MeanReactionTime * 1000, function(v) Settings.MeanReactionTime = v / 1000 end)))
local setTrackErr  = (select(3, CreateLegitSlider("Track Error",       0,   3, Defaults.TrackingError,           function(v) Settings.TrackingError    = v end)))
local setShakeInt  = (select(3, CreateLegitSlider("Shake Intensity",   0,   1, Defaults.ShakeIntensity,          function(v) Settings.ShakeIntensity   = v end)))

setLegitSectionVisible(Settings.Mode == "Legit")

-- Override
CreateLabel("  🖱️  TARGET OVERRIDE", Color3.fromRGB(45, 65, 45))
local setOverrideSens = (select(3, CreateSlider("Override Sensitivity",  1,  50, Defaults.OverrideThreshold,
    function(v) Settings.OverrideThreshold = v end)))
local setOverrideCool = (select(3, CreateSlider("Override Cooldown (s)", 0, 1.5, Defaults.OverrideCooldown,
    function(v) Settings.OverrideCooldown  = v end)))

-- ── applySettingsToUI ──────────────────────────────────────────────────────────
-- Declarative binding table: { setter, settingsKey [, transform] }
-- The loop calls setter(transform and transform(Settings[key]) or Settings[key])
-- for every entry, eliminating one repetitive line per widget.
-- Special cases that need ordering or side-effects beyond the setter itself
-- (locks, wrapper visibility, start/stop) are handled explicitly below the loop.
local UI_BINDINGS = {
    -- General toggles & dropdowns
    { setWallCheck,   "WallCheck"           },
    { setTeamCheck,   "TeamCheck"           },
    { setPrediction,  "Prediction"          },
    { setTargetPart,  "TargetPart"          },
    { setMode,        "Mode"                },
    -- General settings sliders
    { setFOV,         "FOV"                 },
    { setMaxDist,     "MaxDistance"         },
    { setSmoothness,  "Smoothness"          },
    -- Prediction sub-settings
    { setPredBias,    "PredictionFactor"    },
    { setAdaptive,    "AdaptivePrediction"  },
    -- Health check
    { setHealthCheck, "HealthCheckEnabled"  },
    { setHealthMinUI, "HealthMinHP"         },
    { setHealthMaxUI, "HealthMaxHP"         },
    -- Legit sliders (ms conversion)
    { setMinReact,    "MinReactionTime",    function(v) return v * 1000 end },
    { setMaxReact,    "MaxReactionTime",    function(v) return v * 1000 end },
    { setMeanReact,   "MeanReactionTime",   function(v) return v * 1000 end },
    { setTrackErr,    "TrackingError"       },
    { setShakeInt,    "ShakeIntensity"      },
    -- Target override
    { setOverrideSens,"OverrideThreshold"   },
    { setOverrideCool,"OverrideCooldown"    },
    -- Visualisation tab
    { setEspTeamCheck,"EspTeamCheck"        },
    { setEspTeamColors,"EspTeamColors"      },
    { setEspType,     "EspType"             },
    { setPlayerEsp,   "PlayerEspEnabled"    },
    { setEspText,     "EspTextEnabled"      },
}

local function applySettingsToUI()
    for _, b in ipairs(UI_BINDINGS) do
        local setter, key, transform = b[1], b[2], b[3]
        setter(transform and transform(Settings[key]) or Settings[key])
    end

    -- ── Special cases that need explicit ordering or side-effects ─────────────
    -- Slider locks depend on toggle state
    lockPredBias(Settings.AdaptivePrediction)
    lockHealthMin(not Settings.HealthCheckEnabled)
    lockHealthMax(not Settings.HealthCheckEnabled)
    -- Sub-label wrapper visibility
    predSubWrapper.Visible = Settings.Prediction
    hcSubWrapper.Visible   = Settings.HealthCheckEnabled
    -- Legit section visibility
    setLegitSectionVisible(Settings.Mode == "Legit")
    -- Fire last: callbacks trigger start/stop which need all state ready
    setEnabled(Settings.Enabled)
    setEsp(Settings.EspEnabled)
end

-- ── Reset / Save buttons ──────────────────────────────────────────────────────
do
    -- ── RESET button ─────────────────────────────────────────────────────────
    local resetRow = Instance.new("Frame")
    resetRow.Size                = UDim2.new(1, 0, 0, 28)
    resetRow.BackgroundTransparency = 1
    resetRow.Parent              = Content

    local resetBtn = Instance.new("TextButton")
    resetBtn.Size             = UDim2.new(1, 0, 1, 0)
    resetBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 40)
    resetBtn.Text             = "↺  RESET ALL SETTINGS"
    resetBtn.TextColor3       = Color3.new(1, 1, 1)
    resetBtn.Font             = Enum.Font.GothamBold
    resetBtn.TextSize         = 11
    resetBtn.Parent           = resetRow
    local rrc = Instance.new("UICorner") rrc.CornerRadius = UDim.new(0, 4) rrc.Parent = resetBtn

    -- ── SAVE button ──────────────────────────────────────────────────────────
    local saveRow = Instance.new("Frame")
    saveRow.Size                = UDim2.new(1, 0, 0, 28)
    saveRow.BackgroundTransparency = 1
    saveRow.Parent              = Content

    local saveBtn = Instance.new("TextButton")
    saveBtn.Size             = UDim2.new(1, 0, 1, 0)
    saveBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 130)
    saveBtn.Text             = "💾  SAVE SETTINGS"
    saveBtn.TextColor3       = Color3.new(1, 1, 1)
    saveBtn.Font             = Enum.Font.GothamBold
    saveBtn.TextSize         = 11
    saveBtn.Parent           = saveRow
    local src = Instance.new("UICorner") src.CornerRadius = UDim.new(0, 4) src.Parent = saveBtn

    -- ── RESET CONFIRMATION MODAL ─────────────────────────────────────────────
    -- Semi-transparent overlay covering the whole MainFrame.
    -- Sits above all content via ZIndex; hidden until reset is clicked.
    local overlay = Instance.new("Frame")
    overlay.Size             = UDim2.new(1, 0, 1, 0)
    overlay.Position         = UDim2.new(0, 0, 0, 0)
    overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    overlay.BackgroundTransparency = 0.45
    overlay.BorderSizePixel  = 0
    overlay.ZIndex           = 50
    overlay.Visible          = false
    overlay.Parent           = MainFrame

    local card = Instance.new("Frame")
    card.Size             = UDim2.new(0, 220, 0, 120)
    card.AnchorPoint      = Vector2.new(0.5, 0.5)
    card.Position         = UDim2.new(0.5, 0, 0.5, 0)
    card.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    card.BorderSizePixel  = 0
    card.ZIndex           = 51
    card.Parent           = overlay
    local cardC = Instance.new("UICorner") cardC.CornerRadius = UDim.new(0, 8) cardC.Parent = card

    local cardTitle = Instance.new("TextLabel")
    cardTitle.Size                = UDim2.new(1, 0, 0, 30)
    cardTitle.Position            = UDim2.new(0, 0, 0, 8)
    cardTitle.BackgroundTransparency = 1
    cardTitle.Text                = "⚠  Reset to Defaults?"
    cardTitle.TextColor3          = Color3.fromRGB(255, 200, 80)
    cardTitle.Font                = Enum.Font.GothamBold
    cardTitle.TextSize            = 12
    cardTitle.ZIndex              = 51
    cardTitle.Parent              = card

    local cardBody = Instance.new("TextLabel")
    cardBody.Size                = UDim2.new(1, -20, 0, 36)
    cardBody.Position            = UDim2.new(0, 10, 0, 40)
    cardBody.BackgroundTransparency = 1
    cardBody.Text                = "All settings will return to their\ncompiled defaults and the save\nfile will be overwritten."
    cardBody.TextColor3          = Color3.fromRGB(180, 180, 180)
    cardBody.Font                = Enum.Font.Gotham
    cardBody.TextSize            = 10
    cardBody.TextWrapped         = true
    cardBody.ZIndex              = 51
    cardBody.Parent              = card

    local confirmBtn = Instance.new("TextButton")
    confirmBtn.Size             = UDim2.new(0, 90, 0, 22)
    confirmBtn.Position         = UDim2.new(0, 12, 1, -30)
    confirmBtn.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
    confirmBtn.Text             = "✓  Reset"
    confirmBtn.TextColor3       = Color3.new(1, 1, 1)
    confirmBtn.Font             = Enum.Font.GothamBold
    confirmBtn.TextSize         = 11
    confirmBtn.ZIndex           = 52
    confirmBtn.Parent           = card
    local cfc = Instance.new("UICorner") cfc.CornerRadius = UDim.new(0, 4) cfc.Parent = confirmBtn

    local cancelBtn = Instance.new("TextButton")
    cancelBtn.Size             = UDim2.new(0, 90, 0, 22)
    cancelBtn.Position         = UDim2.new(1, -102, 1, -30)
    cancelBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
    cancelBtn.Text             = "✕  Cancel"
    cancelBtn.TextColor3       = Color3.new(1, 1, 1)
    cancelBtn.Font             = Enum.Font.GothamBold
    cancelBtn.TextSize         = 11
    cancelBtn.ZIndex           = 52
    cancelBtn.Parent           = card
    local cxc = Instance.new("UICorner") cxc.CornerRadius = UDim.new(0, 4) cxc.Parent = cancelBtn

    -- ── Wire buttons ─────────────────────────────────────────────────────────
    resetBtn.MouseButton1Click:Connect(function()
        overlay.Visible = true
    end)

    cancelBtn.MouseButton1Click:Connect(function()
        overlay.Visible = false
    end)

    confirmBtn.MouseButton1Click:Connect(function()
        overlay.Visible = false

        -- 1. Stop any active aimbot step cleanly before wiping state.
        stopAimbot()

        -- 2. Reset all widget visuals + callbacks to hardcoded defaults.
        for _, fn in ipairs(uiResets) do fn() end

        -- 3. Restore any WhitelistedTeams that uiResets can't reach.
        table.clear(Settings.WhitelistedTeams)

        -- 3. Overwrite the save file with hardcoded defaults so next boot
        --    starts clean.  Temporarily point Settings at HardDefaults,
        --    serialize, then let Settings drift back via the callbacks above.
        local savedSettings = Settings
        Settings = HardDefaults
        local ok, _ = saveSettings()
        Settings = savedSettings
        -- Restore actual runtime values from HardDefaults.
        for k, v in pairs(HardDefaults) do
            if k ~= "WhitelistedTeams" then
                Settings[k] = v
            end
        end

        -- 4. Brief green flash on reset button.
        resetBtn.BackgroundColor3 = Color3.fromRGB(50, 180, 50)
        resetBtn.Text = "✓  Reset to Defaults!"
        task.delay(1.2, function()
            resetBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 40)
            resetBtn.Text = "↺  RESET ALL SETTINGS"
        end)
    end)

    saveBtn.MouseButton1Click:Connect(function()
        local ok, err = saveSettings()
        if ok then
            saveBtn.BackgroundColor3 = Color3.fromRGB(30, 160, 60)
            saveBtn.Text = "✓  Saved!"
        else
            saveBtn.BackgroundColor3 = Color3.fromRGB(160, 50, 50)
            saveBtn.Text = "✕  Save Failed"
            warn("[AimbotUI] Save error: " .. tostring(err))
        end
        task.delay(1.2, function()
            saveBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 130)
            saveBtn.Text = "💾  SAVE SETTINGS"
        end)
    end)
end

-- ============================================================
