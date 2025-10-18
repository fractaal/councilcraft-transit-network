-- update.lua
-- Quick updater for CouncilCraft Transit Network
-- Usage: Just run "update" to update transit.lua from pastebin

local CONFIG_FILE = "/.update_config"
local DEFAULT_PASTEBIN_ID = "uNwTJ5Sc"
local TARGET_FILE = "startup/transit.lua"

-- Load or create update config
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local file = fs.open(CONFIG_FILE, "r")
        local content = file.readAll()
        file.close()
        local config = textutils.unserialize(content)
        return config
    else
        -- Create default config
        local config = {
            pastebin_id = DEFAULT_PASTEBIN_ID
        }
        local file = fs.open(CONFIG_FILE, "w")
        file.write(textutils.serialize(config))
        file.close()
        return config
    end
end

-- Main update function
local function update()
    print("CouncilCraft Transit Network Updater")
    print("====================================")
    print("")

    local config = loadConfig()
    print("Pastebin ID: " .. config.pastebin_id)
    print("Target: " .. TARGET_FILE)
    print("")

    -- Delete old file if it exists
    if fs.exists(TARGET_FILE) then
        print("Deleting old version...")
        fs.delete(TARGET_FILE)
    end

    -- Download from pastebin
    print("Downloading from pastebin...")
    local result = shell.run("pastebin", "get", config.pastebin_id, TARGET_FILE)

    if not result then
        print("")
        print("ERROR: Failed to download from pastebin!")
        print("Check your pastebin ID in " .. CONFIG_FILE)
        return false
    end

    print("")
    print("Update successful!")
    print("")
    write("Reboot now? (y/n): ")
    local response = read()

    if response == "y" or response == "Y" then
        print("Rebooting...")
        sleep(1)
        os.reboot()
    else
        print("Update complete. Run 'reboot' when ready.")
    end

    return true
end

-- Run the updater
update()
