local OUTPUT ="D:/SteamLibrary/steamapps/common/Shutter/Shutter/Binaries/Win64/ue4ss/Mods/ShutterTASDiscovery/discovery_actors.txt"

------------------------------------------------------------
-- Keywords that are interesting for TAS state discovery
------------------------------------------------------------

local keywords = {
    -- Player
    "player",
    "character",
    "pawn",
    "controller",

    -- Game state
    "gamestate",
    "gameinstance",
    "playerstate",
    "gamemode",

    -- Interaction / progression
    "interact",
    "trigger",
    "objective",
    "quest",
    "mission",
    "checkpoint",
    "progress",

    -- Puzzle
    "puzzle",
    "switch",
    "lever",
    "button",
    "keypad",
    "computer",
    "cube",
    "gravity",
    "conveyor",

    -- Doors / level progression
    "door",
    "gate",
    "lock",
    "elevator",

    -- Inventory / items
    "inventory",
    "item",
    "key",
    "weapon",

    -- NPC / AI
    "enemy",
    "npc",
    "ai",

    -- Spawning / save
    "spawn",
    "save",
    "checkpoint"
}

------------------------------------------------------------
-- Utility
------------------------------------------------------------

local function contains_keyword(name)
    name = string.lower(name)

    for _, keyword in ipairs(keywords) do
        if string.find(name, keyword, 1, true) then
            return true
        end
    end

    return false
end


local function is_runtime_object(name)
    -- We are interested in objects belonging to loaded levels.
    --
    -- This eliminates a lot of:
    --   /Script/...
    --   /Engine/...
    --   /Game/... Blueprint definitions
    --
    -- while retaining:
    --   /Game/Maps/...PersistentLevel.ActorName

    if string.find(name, "PersistentLevel", 1, true) then
        return true
    end

    return false
end


------------------------------------------------------------
-- Discovery
------------------------------------------------------------

local function discover()

    local file = io.open(OUTPUT, "w")

    if not file then
        print("[ShutterTAS] ERROR: Could not open " .. OUTPUT)
        return
    end

    file:write("============================================================\n")
    file:write("SHUTTER TAS - RUNTIME ACTOR DISCOVERY\n")
    file:write("============================================================\n\n")

    local count = 0

    ForEachUObject(function(obj)

        if not obj then
            return
        end

        local full_name = obj:GetFullName()

        --------------------------------------------------------
        -- Only objects belonging to a loaded level
        --------------------------------------------------------

        if not is_runtime_object(full_name) then
            return
        end


        --------------------------------------------------------
        -- Only interesting gameplay objects
        --------------------------------------------------------

        if not contains_keyword(full_name) then
            return
        end


        --------------------------------------------------------
        -- Record object
        --------------------------------------------------------

        count = count + 1

        file:write(string.format(
            "[%04d] %s\n",
            count,
            full_name
        ))

    end)

    file:write("\n============================================================\n")
    file:write(string.format("TOTAL: %d runtime gameplay objects\n", count))
    file:write("============================================================\n")

    file:close()

    print(
        string.format(
            "[ShutterTAS] Runtime actor discovery complete: %d objects",
            count
        )
    )

end


------------------------------------------------------------
-- Wait until the level has loaded
------------------------------------------------------------

ExecuteWithDelay(10000, discover)
