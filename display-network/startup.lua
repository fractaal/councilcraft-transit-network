--[[
    Display Network Auto-start Script
    Place this in /startup.lua on your ComputerCraft computer
]]

-- Check if display program exists
if not fs.exists("/display.lua") then
    print("Display Network not found!")
    print("Run: composer install display-network")
    return
end

-- Start display program
shell.run("/display.lua")
