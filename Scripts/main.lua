local function log(msg)
print("[TIME TEST] " .. tostring(msg))
end

log("==============================================")
log("Blueprint time function test")
log("==============================================")

-- Find the current MainLevel world.
local worlds = FindAllOf("World")
local world = nil

for _, w in ipairs(worlds) do
local ok, name = pcall(function()
return w()
end)

if ok and name and string.find(tostring(name), "MainLevel", 1, true) then
    world = w
    break
end

end

if not world then
log("ERROR: MainLevel world not found")
return
end

log("World = " .. tostring(world()))

-- Test 1: UWorld

local ok, result = pcall(function()
return world("GetTimeSeconds")
end)

log("UWorld")
log(" call success = " .. tostring(ok))
log(" result type = " .. tostring(type(result)))
log(" result = " .. tostring(result))

-- Test 2: GameplayStatics

local ok2, result2 = pcall(function()
return world(
"/Script/Engine.GameplayStatics"
)
end)

log("GameplayStatics")
log(" call success = " .. tostring(ok2))
log(" result type = " .. tostring(type(result2)))
log(" result = " .. tostring(result2))

-- Test 3: KismetSystemLibrary

local ok3, result3 = pcall(function()
return world(
"/Script/Engine.KismetSystemLibrary"
)
end)

log("KismetSystemLibrary")
log(" call success = " .. tostring(ok3))
log(" result type = " .. tostring(type(result3)))
log(" result = " .. tostring(result3))

-- Test 4: direct Lua function access

local ok4, result4 = pcall(function()
return world()
end)

log("Direct world()")
log(" call success = " .. tostring(ok4))
log(" result type = " .. tostring(type(result4)))
log(" result = " .. tostring(result4))

log("==============================================")
log("END")
log("==============================================")
