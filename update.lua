-- update.lua
-- Quick updater for CouncilCraft Transit Network
-- Usage: Just run "update" to update transit.lua from GitHub

local CONFIG_FILE = "/.update_config"
local DEFAULT_GITHUB_URL = "https://raw.githubusercontent.com/fractaal/councilcraft-transit-network/main/transit.lua"
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
            github_url = DEFAULT_GITHUB_URL
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

    -- Safety check for github_url
    if not config.github_url or config.github_url == "" then
        print("WARNING: No GitHub URL in config, using default...")
        config.github_url = DEFAULT_GITHUB_URL
        -- Save fixed config
        local file = fs.open(CONFIG_FILE, "w")
        file.write(textutils.serialize(config))
        file.close()
    end

    print("GitHub URL: " .. config.github_url)
    print("Target: " .. TARGET_FILE)
    print("")

    -- Delete old file if it exists
    if fs.exists(TARGET_FILE) then
        print("Deleting old version...")
        fs.delete(TARGET_FILE)
    end

    -- Download from GitHub
    print("Downloading from GitHub...")
    local response = http.get(config.github_url)

    if not response then
        print("")
        print("ERROR: Failed to download from GitHub!")
        print("Check your GitHub URL in " .. CONFIG_FILE)
        return false
    end

    -- Read content
    local content = response.readAll()
    response.close()

    -- Write to file
    local file = fs.open(TARGET_FILE, "w")
    file.write(content)
    file.close()

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
