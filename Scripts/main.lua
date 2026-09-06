local OUTPUT = "D:/SteamLibrary/steamapps/common/Shutter/Shutter/Binaries/Win64/ue4ss/Mods/ShutterTASDiscovery/player_candidates.txt"
local function discover()

    local file = io.open(OUTPUT, "w")

    if not file then
        print("[ShutterTAS] ERROR: Could not open output")
        return
    end

    file:write("=== PLAYER / CHARACTER CANDIDATES ===\n\n")

    local count = 0

    ForEachUObject(function(obj)

        if not obj then
            return
        end

        local name = obj:GetFullName()

        -- Only objects belonging to a loaded level
        if not string.find(name, "PersistentLevel", 1, true) then
            return
        end

        local lower = string.lower(name)

        --------------------------------------------------------
        -- Much stricter than before.
        --
        -- Do NOT match generic "player", because things like
        -- AnimationPlayer / SequenceDirector can contain it.
        --------------------------------------------------------

        local candidate =
            string.find(lower, "character", 1, true)
            or string.find(lower, "firstperson", 1, true)
            or string.find(lower, "thirdperson", 1, true)
            or string.find(lower, "pawn", 1, true)
            or string.find(lower, "playercontroller", 1, true)

        if not candidate then
            return
        end

        count = count + 1

        file:write(string.format(
            "[%03d] %s\n",
            count,
            name
        ))

        print("[ShutterTAS] Candidate:")
        print(name)

    end)

    file:write("\nTOTAL: " .. tostring(count) .. "\n")

    file:close()

    print(
        "[ShutterTAS] Candidate discovery complete: "
        .. tostring(count)
    )

end


ExecuteWithDelay(10000, discover)
