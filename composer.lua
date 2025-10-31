-- Composer CLI for CouncilCraft packages
local tArgs = { ... }

if not package.path:find("/lib/%.%?%.lua", 1, true) then
  package.path = "/lib/?.lua;/lib/?/init.lua;" .. package.path
end

local ok, composer = pcall(require, "composer")
if not ok or not composer then
  print("composer: unable to load /lib/composer.lua")
  return
end

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
