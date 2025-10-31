-- Composer CLI for CouncilCraft packages
local tArgs = { ... }

local function ensure_module()
  if not package.path:find("/lib/%.%?%.lua", 1, true) then
    package.path = "/lib/?.lua;/lib/?/init.lua;" .. package.path
  end

  local ok, mod = pcall(require, "composer")
  if ok and mod then
    return mod
  end

  local url = "https://raw.githubusercontent.com/fractaal/councilcraft-transit-network/main/lib/composer.lua"
  print("composer: bootstrapping module from repo...")
  local resp = http.get(url)
  if not resp then
    error("composer: failed to download module from " .. url, 0)
  end
  if not fs.exists("/lib") then
    fs.makeDir("/lib")
  end
  local handle = fs.open("/lib/composer.lua", "w")
  handle.write(resp.readAll())
  handle.close()
  resp.close()

  local ok2, mod2 = pcall(require, "composer")
  if not ok2 or not mod2 then
    error("composer: unable to load module after bootstrap", 0)
  end
  return mod2
end

local composer = ensure_module()

local function print_usage()
  print("CouncilCraft Composer")
  print("Usage: composer <command> [args]\n")
  print("Commands:")
  print("  install <package>  - install or update a package")
  print("  update <package>   - alias for install")
  print("  list               - show installed packages")
  print("  check <package> <current_version> - check for updates")
end

if #tArgs == 0 then
  print_usage()
  return
end

local cmd = tArgs[1]

if cmd == "install" or cmd == "update" then
  local pkg = tArgs[2]
  if not pkg then
    print("composer: package name required")
    return
  end
  write(string.format("Installing '%s'... ", pkg))
  local ok, result = composer.install(pkg)
  if ok then
    print("done")
    if result then
      print("  version: " .. tostring(result))
    end
  else
    print("failed")
    if result then
      print("  " .. tostring(result))
    end
  end
elseif cmd == "list" then
  local packages = composer.list()
  if #packages == 0 then
    print("No packages installed.")
    return
  end
  print("Installed packages:")
  for _, info in ipairs(packages) do
    print(string.format("  %s (%s)", info.name, info.version or "unknown"))
  end
elseif cmd == "check" then
  local pkg = tArgs[2]
  local current = tArgs[3]
  if not pkg or not current then
    print("composer: usage: composer check <package> <current_version>")
    return
  end
  local result = composer.check(pkg, current)
  if not result.ok then
    print("composer: check failed - " .. tostring(result.error))
    return
  end
  print(string.format("Latest: %s", tostring(result.version or "unknown")))
  if result.update_available then
    print("Update available")
  else
    print("Already up to date")
  end
else
  print("composer: unknown command '" .. cmd .. "'")
  print_usage()
end
