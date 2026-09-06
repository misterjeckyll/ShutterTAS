local OUTPUT = "D:/SteamLibrary/steamapps/common/Shutter/Shutter/Binaries/Win64/ue4ss/Mods/ShutterTASDiscovery/discovery.txt"

local keywords = {
    "player", "character", "pawn", "controller",
    "gamestate", "gamemode", "gameinstance",
    "inventory", "item", "weapon",
    "door", "puzzle", "switch", "lever", "button",
    "trigger", "interact",
    "objective", "quest", "mission",
    "checkpoint", "progress",
    "enemy", "npc", "ai",
    "save", "random", "seed", "spawn"
}

local function contains_keyword(name)
    name = string.lower(name)

    for _, keyword in ipairs(keywords) do
        if string.find(name, keyword, 1, true) then
            return true
        end
    end

    return false
end

local file = nil

local function discover()
    file = io.open(OUTPUT, "w")

    if not file then
        print("[ShutterTAS] Could not open " .. OUTPUT)
        return
    end

    file:write("=== SHUTTER UE4SS OBJECT DISCOVERY ===\n\n")

    ForEachUObject(function(obj)
        if not obj then
            return
        end

        local name = obj:GetFullName()

        if contains_keyword(name) then
            file:write(name .. "\n")
        end
    end)

    file:close()

    print("[ShutterTAS] Discovery complete: " .. OUTPUT)
end

ExecuteWithDelay(10000, discover)
