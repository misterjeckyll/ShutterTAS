-- ============================================================================
-- Shutter TAS - UE4SS Runtime Object Discovery
--
-- Purpose:
--   Discover gameplay objects/classes currently existing in the running game.
--
-- Output:
--   UE4SS/Mods/ShutterTASDiscovery/discovery.txt
--
-- Designed as a DISCOVERY tool first.
-- It does NOT modify game state.
-- ============================================================================

local MenuDiscovery = require("MenuDiscovery")
local OUTPUT_FILE = "D:/SteamLibrary/steamapps/common/Shutter/Shutter/Binaries/Win64/ue4ss/Mods/ShutterTASDiscovery/discovery.txt"

local INCLUDE_ALL_ACTORS = true

-- Objects whose names contain these strings get a higher priority.
local IMPORTANT_KEYWORDS = {
    "player",
    "character",
    "pawn",
    "controller",
    "playerstate",
    "gamestate",
    "gamemode",
    "gameinstance",

    "inventory",
    "item",
    "weapon",

    "door",
    "puzzle",
    "switch",
    "lever",
    "button",
    "trigger",
    "interact",

    "objective",
    "quest",
    "mission",
    "checkpoint",
    "progress",

    "enemy",
    "npc",
    "ai",

    "timer",
    "random",
    "seed",
    "spawn",

    "save",
}


local IGNORE_KEYWORDS = {
    "widget",
    "font",
    "texture",
    "material",
    "sound",
    "audio",
    "particle",
    "niagara",
    "skeletalmesh",
    "staticmesh",
    "animsequence",
}


-- ============================================================================
-- Utility
-- ============================================================================

local function safe_tostring(value)

    local ok, result = pcall(function()
        return tostring(value)
    end)

    if ok then
        return result
    end

    return "<unprintable>"
end


local function lower(value)

    return string.lower(
        safe_tostring(value)
    )

end


local function contains(text, keyword)

    return string.find(
        lower(text),
        keyword,
        1,
        true
    ) ~= nil

end


local function is_important(name)

    local score = 0
    local matches = {}

    local lname = lower(name)

    for _, keyword in ipairs(IMPORTANT_KEYWORDS) do

        if string.find(
            lname,
            keyword,
            1,
            true
        ) then

            score = score + 1

            table.insert(
                matches,
                keyword
            )

        end
    end

    return score, matches
end


local function should_ignore(name)

    local lname = lower(name)

    for _, keyword in ipairs(IGNORE_KEYWORDS) do

        if string.find(
            lname,
            keyword,
            1,
            true
        ) then

            return true
        end
    end

    return false
end


local function write(file, text)

    file:write(
        text .. "\n"
    )

end


-- ============================================================================
-- Object information
-- ============================================================================

local function get_object_name(obj)

    local ok, result = pcall(function()

        if obj.GetFullName then
            return obj:GetFullName()
        end

        return obj:GetName()

    end)

    if ok then
        return safe_tostring(result)
    end

    return "<unknown>"
end


local function get_class_name(obj)

    local ok, result = pcall(function()

        local cls = obj:GetClass()

        if cls then

            if cls.GetFullName then
                return safe_tostring(
                    cls:GetFullName()
                )
            end

            return safe_tostring(cls)
        end

        return "<unknown>"

    end)

    if ok then
        return result
    end

    return "<unknown>"
end


local function get_outer_name(obj)

    local ok, result = pcall(function()

        if obj.GetOuter then

            local outer = obj:GetOuter()

            if outer then
                return get_object_name(outer)
            end
        end

        return "<none>"

    end)

    if ok then
        return result
    end

    return "<unknown>"
end


-- ============================================================================
-- Property discovery
--
-- UE4SS versions expose different property reflection helpers.
-- We therefore try several mechanisms rather than assuming one API.
-- ============================================================================

local function dump_properties(obj, file)

    write(file, "  PROPERTIES:")

    local found = false


    -- ------------------------------------------------------------------------
    -- Method 1: GetProperties()
    -- ------------------------------------------------------------------------

    local ok, properties = pcall(function()

        if obj.GetProperties then
            return obj:GetProperties()
        end

        return nil

    end)


    if ok and properties then

        found = true

        local property_count = 0

        for _, property in pairs(properties) do

            property_count =
                property_count + 1

            if property_count > 500 then
                break
            end

            local pname = safe_tostring(property)

            write(
                file,
                "    - " .. pname
            )
        end
    end


    -- ------------------------------------------------------------------------
    -- Method 2: reflection through the object's class
    -- ------------------------------------------------------------------------

    local ok_class, cls = pcall(function()

        return obj:GetClass()

    end)


    if ok_class and cls then

        -- Try GetPropertyByName if available.
        --
        -- We cannot know the property names beforehand, so this section
        -- becomes useful when a future UE4SS API exposes property iteration.
        --
        -- Kept here intentionally for compatibility with different builds.

        local ok_props, class_props = pcall(function()

            if cls.GetProperties then
                return cls:GetProperties()
            end

            return nil

        end)


        if ok_props and class_props then

            found = true

            local count = 0

            for _, property in pairs(class_props) do

                count = count + 1

                if count > 500 then
                    break
                end

                write(
                    file,
                    "    - " ..
                    safe_tostring(property)
                )

            end
        end
    end


    if not found then

        write(
            file,
            "    <property enumeration unavailable>"
        )

    end
end


-- ============================================================================
-- Actor transform
-- ============================================================================

local function dump_transform(obj, file)

    -- GetActorLocation()
    local ok_location, location = pcall(function()

        if obj.GetActorLocation then
            return obj:GetActorLocation()
        end

        return nil

    end)


    if ok_location and location then

        write(
            file,
            "  LOCATION: " ..
            safe_tostring(location)
        )

    end


    -- GetActorRotation()
    local ok_rotation, rotation = pcall(function()

        if obj.GetActorRotation then
            return obj:GetActorRotation()
        end

        return nil

    end)


    if ok_rotation and rotation then

        write(
            file,
            "  ROTATION: " ..
            safe_tostring(rotation)
        )

    end
end


-- ============================================================================
-- Single object
-- ============================================================================

local function dump_object(obj, file, index)

    local name = get_object_name(obj)
    local class = get_class_name(obj)

    local score, matches =
        is_important(name .. " " .. class)

    if should_ignore(name) and score == 0 then
        return false
    end


    write(file, "")
    write(file, "============================================================")

    write(
        file,
        string.format(
            "OBJECT #%d",
            index
        )
    )

    write(
        file,
        "NAME: " .. name
    )

    write(
        file,
        "CLASS: " .. class
    )

    write(
        file,
        "OUTER: " ..
        get_outer_name(obj)
    )

    write(
        file,
        "IMPORTANCE: " ..
        tostring(score)
    )


    if #matches > 0 then

        write(
            file,
            "KEYWORDS: " ..
            table.concat(
                matches,
                ", "
            )
        )

    end


    -- Actor-specific state.
    dump_transform(
        obj,
        file
    )


    -- Properties.
    dump_properties(
        obj,
        file
    )

    return true
end


-- ============================================================================
-- Main discovery
-- ============================================================================

local function discover()

    print(
        "[ShutterTAS] Starting runtime object discovery..."
    )


    local file, error_message =
        io.open(
            OUTPUT_FILE,
            "w"
        )


    if not file then

        print(
            "[ShutterTAS] ERROR: Cannot open output file: " ..
            safe_tostring(error_message)
        )

        return
    end


    write(
        file,
        "SHUTTER UE4SS TAS DISCOVERY"
    )

    write(
        file,
        "=============================================="
    )

    write(
        file,
        "Generated by ShutterTASDiscovery"
    )

    write(
        file,
        ""
    )


    -- ------------------------------------------------------------------------
    -- UObject enumeration
    -- ------------------------------------------------------------------------

    local objects = nil


    local ok, result = pcall(function()

        if GetObjects then
            return GetObjects()
        end

        return nil

    end)


    if ok then
        objects = result
    end


    if not objects then

        write(
            file,
            "ERROR: GetObjects() unavailable."
        )

        file:close()

        print(
            "[ShutterTAS] GetObjects() unavailable."
        )

        return
    end


    local count = 0
    local interesting = 0


    for _, obj in pairs(objects) do

        count = count + 1

        local ok_object =
            pcall(function()

                if dump_object(
                    obj,
                    file,
                    count
                ) then

                    interesting =
                        interesting + 1
                end

            end)

    end


    write(file, "")
    write(file, "==============================================")
    write(file, "STATISTICS")
    write(file, "==============================================")

    write(
        file,
        "Objects enumerated: " ..
        tostring(count)
    )

    write(
        file,
        "Interesting objects: " ..
        tostring(interesting)
    )


    file:close()


    print(
        "[ShutterTAS] Discovery complete."
    )

    print(
        "[ShutterTAS] Objects: " ..
        tostring(count)
    )

    print(
        "[ShutterTAS] Interesting: " ..
        tostring(interesting)
    )

    print(
        "[ShutterTAS] Output: " ..
        OUTPUT_FILE
    )
end


-- ============================================================================
-- Delayed execution
--
-- We want the game to have loaded its map and spawned its actors before
-- enumerating them.
-- ============================================================================

ExecuteWithDelay(
    10000,
    discover
)
