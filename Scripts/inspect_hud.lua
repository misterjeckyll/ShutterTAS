
--============================================================
-- ShutterTAS - UE4SS HUD Injector
--============================================================
--
-- Purpose:
--   Inject the game's native HUDWidget_C through UE4SS.
--
-- Known Shutter UI classes:
--   /Game/UI/HUD/HUDWidget.HUDWidget_C
--
-- Controls:
--   F7 = Toggle TAS HUD
--   F8 = Dump HUD widget information
--
--============================================================

local MOD_NAME = "ShutterTAS"

local HUD_CLASS_PATH =
    "/Game/UI/HUD/HUDWidget.HUDWidget_C"

local hudClass = nil
local hudWidget = nil
local hudVisible = true
local initialized = false

local DEBUG = true


--============================================================
-- Logging
--============================================================

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end


local function debug(message)
    if DEBUG then
        log(message)
    end
end


-- Declare ici : is_valid est definie plus bas dans le fichier, et Lua
-- resoudrait sinon l'appel sur un global nil.
local is_valid

local function inspect_widget_class(class_path)
log("================================================")
log("INSPECTING CLASS")
log(class_path)
log("================================================")


local cls = StaticFindObject(class_path)

if not is_valid(cls) then
    log("Class not found: " .. class_path)
    return
end

log("Class object:")
log(tostring(cls))

local okName, name = pcall(function()
    return cls:GetFullName()
end)

if okName then
    log("FullName: " .. tostring(name))
end

log("------------------------------------------------")
log("Attempting property inspection...")
log("------------------------------------------------")

local okMembers, members = pcall(function()
    return cls:GetProperties()
end)

if okMembers and members ~= nil then
    log("Properties:")
    log(tostring(members))
else
    log("GetProperties unavailable on this UE4SS build.")
end

log("------------------------------------------------")
log("Attempting function inspection...")
log("------------------------------------------------")

local okFunctions, functions = pcall(function()
    return cls:GetFunctions()
end)

if okFunctions and functions ~= nil then
    log("Functions:")
    log(tostring(functions))
else
    log("GetFunctions unavailable on this UE4SS build.")
end

log("================================================")

end


--============================================================
-- Safe UObject helpers
--============================================================

function is_valid(obj)
    if obj == nil then
        return false
    end

    local ok, result = pcall(function()
        if obj.IsValid then
            return obj:IsValid()
        end

        return true
    end)

    return ok and result == true
end


local function safe_call(label, fn)
    local ok, result = pcall(fn)

    if not ok then
        log(label .. " failed: " .. tostring(result))
        return nil
    end

    return result
end


local function inspect_interact_instances()
log("================================================")
log("LIVE INTERACT WIDGET INSTANCES")
log("================================================")


local widgets = FindAllOf("InteractWidget_C")

if widgets == nil then
    log("FindAllOf returned nil.")
    return
end

log("Instances found: " .. tostring(#widgets))
log("------------------------------------------------")

for i, param in ipairs(widgets) do
    local widget = nil

    local okUnwrap, result = pcall(function()
        return param:get()
    end)

    if okUnwrap then
        widget = result
    end

    if widget ~= nil then
        log("[" .. tostring(i) .. "]")

        local okName, fullName = pcall(function()
            return widget:GetFullName()
        end)

        if okName then
            log("  Object: " .. tostring(fullName))
        end

        local okPosition, position = pcall(function()
            return widget.LastPosition
        end)

        if okPosition then
            log("  LastPosition: " .. tostring(position))
        else
            log("  LastPosition: <unavailable>")
        end

        local okNav, navMode = pcall(function()
            return widget.CurrentNavMode
        end)

        if okNav then
            log("  CurrentNavMode: " .. tostring(navMode))
        else
            log("  CurrentNavMode: <unavailable>")
        end

        local okText, textWidget = pcall(function()
            return widget.InteractText
        end)

        if okText and textWidget ~= nil then
            log("  InteractText object: " .. tostring(textWidget))

            local okTextValue, textValue = pcall(function()
                return textWidget:GetText()
            end)

            if okTextValue then
                log("  InteractText value: " .. tostring(textValue))
            else
                log("  InteractText value: <GetText failed>")
            end
        else
            log("  InteractText: <unavailable>")
        end
    else
        log("[" .. tostring(i) .. "] <could not unwrap>")
    end
end

log("================================================")

end

-------------------------------------------------------------------------------------------------------------------------
local function inspect_interact_instances()
log("================================================")
log("LIVE INTERACT WIDGET STATE")
log("================================================")

local widgets = FindAllOf("InteractWidget_C")

if widgets == nil then
    log("FindAllOf returned nil.")
    return
end

log("Instances found: " .. tostring(#widgets))
log("------------------------------------------------")

for i, widget in ipairs(widgets) do
    log("[" .. tostring(i) .. "]")

    if widget == nil then
        log("  <nil>")
    else
        local okName, fullName = pcall(function()
            return widget:GetFullName()
        end)

        if okName then
            log("  " .. tostring(fullName))
        end

        local okPosition, position = pcall(function()
            return widget.LastPosition
        end)

        if okPosition then
            log("  LastPosition = " .. tostring(position))
        end

        local okNav, navMode = pcall(function()
            return widget.CurrentNavMode
        end)

        if okNav then
            log("  CurrentNavMode = " .. tostring(navMode))
        end

        local function inspect_child(label, property_name)
            local okChild, child = pcall(function()
                return widget[property_name]
            end)

            if not okChild or child == nil then
                log("  " .. label .. " = <unavailable>")
                return
            end

            log("  " .. label .. " = " .. tostring(child))

            local okVisibility, visibility = pcall(function()
                return child:GetVisibility()
            end)

            if okVisibility then
                log("    Visibility = " .. tostring(visibility))
            end
        end

        inspect_child("InteractText", "InteractText")
        inspect_child("Background", "Background")
        inspect_child("Icon", "Icon")
        inspect_child("Circle", "Circle")
        inspect_child("Wave", "Wave")
        inspect_child("X", "X")
    end
end

log("================================================")

end



local function inspect_widget_class(class_path)
log("================================================")
log("INSPECTING CLASS")
log(class_path)
log("================================================")

local cls = StaticFindObject(class_path)

if not is_valid(cls) then
    log("Class not found: " .. class_path)
    return
end

log("Class:")
log(cls:GetFullName())

log("------------------------------------------------")
log("REFLECTED PROPERTIES")
log("------------------------------------------------")

local okProperties, propertyError = pcall(function()
    cls:ForEachProperty(function(property)
        if property ~= nil then
            local okName, name = pcall(function()
                return property:GetFullName()
            end)

            if okName then
                log("PROPERTY: " .. tostring(name))
            else
                log("PROPERTY: <unable to get name>")
            end
        end
    end)
end)

if not okProperties then
    log("Property enumeration failed:")
    log(tostring(propertyError))
end

log("------------------------------------------------")
log("REFLECTED FUNCTIONS")
log("------------------------------------------------")

local okFunctions, functionError = pcall(function()
    cls:ForEachFunction(function(func)
        if func ~= nil then
            local okName, name = pcall(function()
                return func:GetFullName()
            end)

            if okName then
                log("FUNCTION: " .. tostring(name))
            else
                log("FUNCTION: <unable to get name>")
            end
        end
    end)
end)

if not okFunctions then
    log("Function enumeration failed:")
    log(tostring(functionError))
end

log("================================================")

end

--============================================================
-- Find the HUD Blueprint class
--============================================================

local function find_hud_class()

    if is_valid(hudClass) then
        return hudClass
    end

    debug("Looking for HUD class:")
    debug(HUD_CLASS_PATH)

    hudClass = StaticFindObject(HUD_CLASS_PATH)

    if is_valid(hudClass) then
        log("Found HUD class: " .. hudClass:GetFullName())
        return hudClass
    end

    -- The Blueprint might not have been loaded yet.
    if LoadAsset then
        debug("HUD class not loaded. Attempting LoadAsset().")

        safe_call("LoadAsset", function()
            LoadAsset(HUD_CLASS_PATH)
        end)

        hudClass = StaticFindObject(HUD_CLASS_PATH)

        if is_valid(hudClass) then
            log("HUD class loaded successfully.")
            log(hudClass:GetFullName())
            return hudClass
        end
    end

    log("HUD class is not available yet.")

    return nil
end


--============================================================
-- Find WidgetBlueprintLibrary
--============================================================

local function get_widget_library()

    local library = StaticFindObject(
        "/Script/UMG.Default__WidgetBlueprintLibrary"
    )

    if not is_valid(library) then
        log("Could not find WidgetBlueprintLibrary.")
        return nil
    end

    return library
end


--============================================================
-- Find PlayerController
--============================================================

local function get_player_controller()

    local controllers = FindAllOf("PlayerController")

    if controllers == nil then
        return nil
    end

    for _, controller in pairs(controllers) do

        if is_valid(controller) then

            local fullName = controller:GetFullName()

            -- Avoid class defaults.
            if not string.find(fullName, "Default__", 1, true) then
                return controller
            end
        end
    end

    return nil
end


--============================================================
-- Find an already existing HUD widget
--============================================================

local function find_existing_hud()

    local widgets = FindAllOf("HUDWidget_C")

    if widgets == nil then
        return nil
    end

    for _, widget in pairs(widgets) do

        if is_valid(widget) then

            local name = widget:GetFullName()

            if not string.find(name, "Default__", 1, true) then
                return widget
            end
        end
    end

    return nil
end


--============================================================
-- Create HUD
--============================================================

local function create_hud()

    -- First check whether the game already created it.
    local existing = find_existing_hud()

    if is_valid(existing) then

        hudWidget = existing

        log("Found existing HUDWidget_C:")
        log(hudWidget:GetFullName())

        return hudWidget
    end


    local class = find_hud_class()

    if not is_valid(class) then
        return nil
    end


    local playerController = get_player_controller()

    if not is_valid(playerController) then
        debug("PlayerController not available yet.")
        return nil
    end


    local widgetLibrary = get_widget_library()

    if not is_valid(widgetLibrary) then
        return nil
    end


    debug("Creating HUDWidget_C...")


    local createFunction = widgetLibrary["Create"]

    if not createFunction then
        log("WidgetBlueprintLibrary.Create was not found.")
        return nil
    end


    local ok, result = pcall(function()

        return createFunction(
            widgetLibrary,
            playerController,
            class,
            nil
        )

    end)


    if not ok then
        log("HUD creation failed:")
        log(tostring(result))
        return nil
    end


    if not is_valid(result) then
        log("HUD creation returned an invalid widget.")
        return nil
    end


    hudWidget = result


    log("HUD created:")
    log(hudWidget:GetFullName())


    -- Add it to the viewport.
    local addToViewport = hudWidget["AddToViewport"]

    if addToViewport then

        local viewportOK = pcall(function()
            addToViewport(hudWidget, 200)
        end)

        if viewportOK then
            log("HUD added to viewport.")
        else
            log("Failed to add HUD to viewport.")
        end

    else
        log("AddToViewport() not available.")
    end


    return hudWidget
end


--============================================================
-- Show / hide HUD
--============================================================

local function set_hud_visibility(visible)

    if not is_valid(hudWidget) then
        return
    end


    if visible then

        local addToViewport = hudWidget["AddToViewport"]

        if addToViewport then
            pcall(function()
                addToViewport(hudWidget, 200)
            end)
        end

        local setOpacity = hudWidget["SetRenderOpacity"]

        if setOpacity then
            pcall(function()
                setOpacity(hudWidget, 1.0)
            end)
        end

        hudVisible = true

        log("TAS HUD: ON")

    else

        local removeFromParent = hudWidget["RemoveFromParent"]

        if removeFromParent then

            pcall(function()
                removeFromParent(hudWidget)
            end)

        else

            local removeFromViewport =
                hudWidget["RemoveFromViewport"]

            if removeFromViewport then
                pcall(function()
                    removeFromViewport(hudWidget)
                end)
            end
        end

        hudVisible = false

        log("TAS HUD: OFF")
    end
end


--============================================================
-- Inspect HUD
--============================================================
local function dump_hud()

    if not is_valid(hudWidget) then
        log("No HUD widget currently exists.")
        return
    end

    log("================================================")
    log("SHUTTER HUD HIERARCHY")
    log("================================================")

    local widgetLibrary = get_widget_library()

    if not is_valid(widgetLibrary) then
        log("WidgetBlueprintLibrary unavailable.")
        return
    end

    local getAllWidgets =
        widgetLibrary["GetAllWidgetsOfClass"]

    if not getAllWidgets then
        log("GetAllWidgetsOfClass unavailable.")
        return
    end

    local userWidgetClass =
        StaticFindObject("/Script/UMG.UserWidget")

    if not is_valid(userWidgetClass) then
        log("UserWidget class unavailable.")
        return
    end

    local children = {}

    local ok, result = pcall(function()

        return getAllWidgets(
            widgetLibrary,
            hudWidget,
            children,
            userWidgetClass,
            false
        )

    end)

    if not ok then
        log("GetAllWidgetsOfClass failed:")
        log(tostring(result))
        return
    end

    log(
        "Widgets returned: "
        .. tostring(#children)
    )

    log("------------------------------------------------")

    for index, param in pairs(children) do

        local child = nil

        -- Unwrap RemoteUnrealParam
        local unwrapOK, unwrapResult = pcall(function()
            return param:get()
        end)

        if unwrapOK then
            child = unwrapResult
        end

        if child ~= nil then

            local fullName = "???"
            local className = "???"

            pcall(function()
                fullName = child:GetFullName()
            end)

            pcall(function()
                className = child:GetClass():GetFullName()
            end)

            log(
                string.format(
                    "[%02d] %s",
                    index,
                    className
                )
            )

            log(
                "     "
                .. tostring(fullName)
            )

        else

            log(
                string.format(
                    "[%02d] <could not unwrap>",
                    index
                )
            )

        end
    end

    log("================================================")
end


--============================================================
-- Initialize
--============================================================

local function initialize()

    if initialized then
        return
    end

    debug("Initialization attempt...")

    local widget = create_hud()

    if not is_valid(widget) then
        debug("HUD not ready. Retrying...")
        return
    end

    initialized = true

    log("================================================")
    log("ShutterTAS HUD initialized")
    log("================================================")
    log("F7 = Toggle HUD")
    log("F8 = Inspect HUD")
    log("================================================")

end


--============================================================
-- Key bindings
--============================================================

RegisterKeyBind(Key.F7, function()

    if not is_valid(hudWidget) then

        log("HUD does not exist yet.")

        initialize()

        return
    end


    set_hud_visibility(not hudVisible)

end)


RegisterKeyBind(Key.F8, function()

    --dump_hud()
   -- inspect_widget_class("/Game/UI/HUD/InteractWidget.InteractWidget_C")
inspect_interact_instances()

end)


--============================================================
-- PlayerController hook
--============================================================

RegisterHook(
    "/Script/Engine.PlayerController:ClientRestart",
    function(Context)

        debug("PlayerController ClientRestart detected.")

        ExecuteWithDelay(500, function()
            initialize()
        end)

    end
)


--============================================================
-- UserWidget construction hook
--============================================================

RegisterHook(
    "/Script/UMG.UserWidget:Construct",
    function(Context)

        ExecuteWithDelay(100, function()

            if not initialized then
                initialize()
            end

        end)

    end
)


--============================================================
-- Startup retry loop
--============================================================

ExecuteWithDelay(1000, function()

    initialize()

end)


ExecuteWithDelay(3000, function()

    if not initialized then
        initialize()
    end

end)


ExecuteWithDelay(6000, function()

    if not initialized then
        initialize()
    end

end)


log("ShutterTAS HUD script loaded.")

