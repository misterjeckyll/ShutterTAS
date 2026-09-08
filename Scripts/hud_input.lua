-- Frame counter is updated every engine frame.
-- Game time is currently disabled because GetTimeSeconds()
-- is exposed as a TrivialObjectValue in this UE4SS build.

--------------------------------------------------------
-- TAS STATE
--------------------------------------------------------
TAS = {
    Frame = 0,
    GameTime = 0.0,
    Visible = true,

    HUD = nil,
    Panel = nil,

    TextFrame = nil,
    TextTime = nil,
    TextInput = nil,
    TextEvent = nil,

    InitHandle = nil,
    TickHandle = nil,

    Forward = 0.0,
    Right = 0.0,

    LastEvent = nil,
    LastKey = nil
}

--------------------------------------------------------
-- LOGGING
--------------------------------------------------------

local function log(msg)
    print("[ShutterTAS] " .. tostring(msg))
end

--------------------------------------------------------
-- FIND HUD
--------------------------------------------------------

local function find_hud()

    local widgets = FindAllOf("HUDWidget_C")

    if not widgets then
        return nil
    end

    if #widgets == 0 then
        return nil
    end

    return widgets[1]
end

--------------------------------------------------------
-- CREATE TEXT BLOCK
--------------------------------------------------------

local function create_text(
    widget_tree,
    parent,
    name,
    x,
    y,
    width,
    height
)

    local text_class = StaticFindObject(
        "/Script/UMG.TextBlock"
    )

    if not text_class then
        return nil
    end

    local text = StaticConstructObject(
        text_class,
        widget_tree,
        name
    )

    if not text then
        return nil
    end

    ----------------------------------------------------
    -- SetFontSize() deliberately NOT used.
    -- It is a TrivialObject in this UE4SS build.
    ----------------------------------------------------

    text:SetText(
        FText("")
    )

    local slot = parent:AddChildToCanvas(text)

    if not slot then
        return nil
    end

    slot:SetPosition({
        X = x,
        Y = y
    })

    slot:SetSize({
        X = width,
        Y = height
    })

    slot:SetZOrder(10)

    return text
end

--------------------------------------------------------
-- CREATE OVERLAY
--------------------------------------------------------

local function create_overlay()

    if TAS.Panel then
        return true
    end

    local hud = find_hud()

    if not hud then
        return false
    end

    TAS.HUD = hud

    local widget_tree = hud.WidgetTree

    if not widget_tree then
        TAS.HUD = nil
        return false
    end

    local root = widget_tree.RootWidget

    if not root then
        TAS.HUD = nil
        return false
    end

    local canvas_class = StaticFindObject(
        "/Script/UMG.CanvasPanel"
    )

    if not canvas_class then
        TAS.HUD = nil
        return false
    end

    local panel = StaticConstructObject(
        canvas_class,
        widget_tree,
        "ShutterTAS_Overlay"
    )

    if not panel then
        TAS.HUD = nil
        return false
    end

    local root_slot = root:AddChild(panel)

    if not root_slot then
        TAS.HUD = nil
        TAS.Panel = nil
        return false
    end

    root_slot:SetZOrder(9999)

    TAS.Panel = panel

    ----------------------------------------------------
    -- FRAME
    ----------------------------------------------------

    TAS.TextFrame = create_text(
        widget_tree,
        panel,
        "TAS_Frame",
        8,
        8,
        300,
        22
    )

    ----------------------------------------------------
    -- TIME
    ----------------------------------------------------

    TAS.TextTime = create_text(
        widget_tree,
        panel,
        "TAS_Time",
        8,
        42,
        300,
        22
    )

    ----------------------------------------------------
    -- INPUT
    ----------------------------------------------------

    TAS.TextInput = create_text(
        widget_tree,
        panel,
        "TAS_Input",
        8,
        76,
        400,
        22
    )

    ----------------------------------------------------
    -- EVENT
    ----------------------------------------------------

    TAS.TextEvent = create_text(
        widget_tree,
        panel,
        "TAS_Event",
        8,
        110,
        400,
        22
    )

    ----------------------------------------------------
    -- INITIAL TEXT
    ----------------------------------------------------

    if TAS.TextFrame then
        TAS.TextFrame:SetText(
            FText("F 00000000")
        )
    end

    if TAS.TextTime then
        TAS.TextTime:SetText(
            FText("T 00:00:00.000")
        )
    end

    if TAS.TextInput then
        TAS.TextInput:SetText(
            FText("I F 0.00 | R 0.00")
        )
    end

    if TAS.TextEvent then
        TAS.TextEvent:SetText(
            FText("E idle")
        )
    end

    TAS.Panel:SetVisibility(0)

    return true
end

--------------------------------------------------------
-- UPDATE FRAME TEXT
--------------------------------------------------------

local function update_frame_text()

    if not TAS.Visible then
        return
    end

    if not TAS.TextFrame then
        return
    end

    TAS.TextFrame:SetText(
        FText(
            string.format(
                "F %08d",
                TAS.Frame
            )
        )
    )
end

--------------------------------------------------------
-- UPDATE TIME TEXT
--------------------------------------------------------

local function update_time_text()

    if not TAS.Visible then
        return
    end

    if not TAS.TextTime then
        return
    end

    local hours = math.floor(
        TAS.GameTime / 3600
    )

    local minutes = math.floor(
        (TAS.GameTime % 3600) / 60
    )

    local seconds = TAS.GameTime % 60

    TAS.TextTime:SetText(
        FText(
            string.format(
                "T %02d:%02d:%06.3f",
                hours,
                minutes,
                seconds
            )
        )
    )
end

--------------------------------------------------------
-- UPDATE INPUT TEXT
--------------------------------------------------------

local function update_input_text()

    if not TAS.Visible then
        return
    end

    if not TAS.TextInput then
        return
    end

    TAS.TextInput:SetText(
        FText(
            string.format(
                "I F %.2f | R %.2f",
                TAS.Forward,
                TAS.Right
            )
        )
    )
end

--------------------------------------------------------
-- UPDATE EVENT
--------------------------------------------------------

local function update_event_text()

    if not TAS.Visible then
        return
    end

    if not TAS.TextEvent then
        return
    end

    TAS.TextEvent:SetText(
        FText("E idle")
    )
end

--------------------------------------------------------
-- UPDATE HUD
--------------------------------------------------------

local function update_hud()

    if not TAS.Panel then
        return
    end

    update_frame_text()
    update_time_text()
    update_input_text()
    update_event_text()
end

--------------------------------------------------------
-- LIVE INPUT DISPLAY
--------------------------------------------------------

local function update_live_input()

    if not TAS.Visible then
        return
    end

    if not TAS.TextInput then
        return
    end

    TAS.TextInput:SetText(
        FText(
            string.format(
                "I F %.2f | R %.2f",
                TAS.Forward,
                TAS.Right
            )
        )
    )
end

--------------------------------------------------------
-- FORWARD AXIS HOOK
--------------------------------------------------------

local ForwardHookInstalled = false

local function install_forward_hook()

    if ForwardHookInstalled then
        return
    end

    RegisterHook(
        "/Game/Blueprints/GameMode/Shutter_PlayerController.Shutter_PlayerController_C:InpAxisEvt_MoveForward/Backwards_K2Node_InputAxisEvent_0",
        function(Context, AxisValue)

            ------------------------------------------------
            -- RemoteUnrealParam:Get() is confirmed safe.
            ------------------------------------------------

            TAS.Forward = AxisValue:Get()

            update_live_input()

        end
    )

    ForwardHookInstalled = true

    log("Forward axis hook installed")
end

--------------------------------------------------------
-- RIGHT AXIS HOOK
--------------------------------------------------------

local RightHookInstalled = false

local function install_right_hook()

    if RightHookInstalled then
        return
    end

    RegisterHook(
        "/Game/Blueprints/GameMode/Shutter_PlayerController.Shutter_PlayerController_C:InpAxisEvt_MoveRight/Left_K2Node_InputAxisEvent_1",
        function(Context, AxisValue)

            ------------------------------------------------
            -- RemoteUnrealParam:Get() is confirmed safe.
            ------------------------------------------------

            TAS.Right = AxisValue:Get()

            update_live_input()

        end
    )

    RightHookInstalled = true

    log("Right axis hook installed")
end

--------------------------------------------------------
-- ENGINE FRAME
--------------------------------------------------------

local function tas_tick()

    ----------------------------------------------------
    -- Stop touching UMG if the HUD is gone.
    ----------------------------------------------------

    if not TAS.HUD then
        return
    end

    if not TAS.Panel then
        return
    end

    if not TAS.TextFrame then
        return
    end

    ----------------------------------------------------
    -- THIS IS THE TAS FRAME.
    --
    -- Increment exactly once for every delayed-action
    -- frame callback.
    ----------------------------------------------------

    TAS.Frame = TAS.Frame + 1

    ----------------------------------------------------
    -- Update frame counter every frame.
    ----------------------------------------------------

    update_frame_text()

    ----------------------------------------------------
    -- Time is currently static.
    --
    -- Do NOT call GetTimeSeconds().
    ----------------------------------------------------

    -- update_time_text()

end

--------------------------------------------------------
-- STOP FRAME LOOP
--------------------------------------------------------

local function stop_tick_loop()

    if TAS.TickHandle then

        CancelDelayedAction(
            TAS.TickHandle
        )

        TAS.TickHandle = nil
    end
end

--------------------------------------------------------
-- START FRAME LOOP
--------------------------------------------------------

local function start_tick_loop()

    if TAS.TickHandle then
        return
    end

    TAS.TickHandle = LoopInGameThreadAfterFrames(
        1,
        function()

            ------------------------------------------------
            -- Do not touch destroyed HUD objects.
            ------------------------------------------------

            if not TAS.HUD or not TAS.Panel then

                stop_tick_loop()

                return
            end

            tas_tick()

        end
    )
end

--------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------

local function try_initialize()

    if not create_overlay() then
        return
    end

    ----------------------------------------------------
    -- Cancel initialization loop.
    ----------------------------------------------------

    if TAS.InitHandle then

        CancelDelayedAction(
            TAS.InitHandle
        )

        TAS.InitHandle = nil
    end

    ----------------------------------------------------
    -- Install live input hooks.
    ----------------------------------------------------

    install_forward_hook()
    install_right_hook()

    ----------------------------------------------------
    -- Initial display.
    ----------------------------------------------------

    update_hud()

    ----------------------------------------------------
    -- Start per-frame TAS counter.
    ----------------------------------------------------

    start_tick_loop()

    log("HUD initialized successfully")
    log("Live axis input active")

end

--------------------------------------------------------
-- F7
--------------------------------------------------------

RegisterKeyBind(
    Key.F7,
    function()

        TAS.Visible = not TAS.Visible

        if TAS.Panel then

            if TAS.Visible then

                TAS.Panel:SetVisibility(0)

                update_frame_text()
                update_input_text()

            else

                TAS.Panel:SetVisibility(1)

            end
        end
    end
)

--------------------------------------------------------
-- F8 DEBUG
--------------------------------------------------------

RegisterKeyBind(
    Key.F8,
    function()

        log("----------------------------------------")
        log("TAS DEBUG")

        log(
            "Frame      = " ..
            tostring(TAS.Frame)
        )

        log(
            "GameTime   = " ..
            tostring(TAS.GameTime)
        )

        log(
            "Visible    = " ..
            tostring(TAS.Visible)
        )

        log(
            "Forward    = " ..
            tostring(TAS.Forward)
        )

        log(
            "Right      = " ..
            tostring(TAS.Right)
        )

        log(
            "HUD        = " ..
            tostring(TAS.HUD)
        )

        log(
            "Panel      = " ..
            tostring(TAS.Panel)
        )

        log(
            "TextFrame  = " ..
            tostring(TAS.TextFrame)
        )

        log(
            "TextTime   = " ..
            tostring(TAS.TextTime)
        )

        log(
            "TextInput  = " ..
            tostring(TAS.TextInput)
        )

        log(
            "TextEvent  = " ..
            tostring(TAS.TextEvent)
        )

        log(
            "InitHandle = " ..
            tostring(TAS.InitHandle)
        )

        log(
            "TickHandle = " ..
            tostring(TAS.TickHandle)
        )

        log(
            "ForwardHook = " ..
            tostring(ForwardHookInstalled)
        )

        log(
            "RightHook   = " ..
            tostring(RightHookInstalled)
        )

        log("----------------------------------------")
    end
)

--------------------------------------------------------
-- STARTUP
--------------------------------------------------------

log("ShutterTAS loaded")
log("Compact TAS HUD")
log(
    "EngineTickAvailable = " ..
    tostring(EngineTickAvailable)
)
log("F7 = Toggle HUD")
log("F8 = Debug")

--------------------------------------------------------
-- WAIT FOR HUD
--------------------------------------------------------

TAS.InitHandle = LoopInGameThreadWithDelay(
    500,
    function()
        try_initialize()
    end
)
