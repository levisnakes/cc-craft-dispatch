-- Reboot every turtle on this modem network (all your crafting stations), then this one.
-- Install it on any one station. Usage:
--   rebootall          ask first
--   rebootall -y       no question
--   rebootall others   leave this turtle running

local args = { ... }
local yes, keepSelf = false, false
for _, a in ipairs(args) do
  if a == "-y" then yes = true end
  if a == "others" then keepSelf = true end
end

local targets = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.hasType(name, "turtle") then table.insert(targets, name) end
end
table.sort(targets)

print("Turtles on the network: " .. #targets)
for _, name in ipairs(targets) do
  local ok, label = pcall(peripheral.call, name, "getLabel")
  local okId, id = pcall(peripheral.call, name, "getID")
  print("  " .. name .. "  #" .. tostring(okId and id or "?") .. "  " .. tostring(ok and label or ""))
end
if not keepSelf then print("  and this turtle, #" .. os.getComputerID() .. " (last)") end

if #targets == 0 and keepSelf then
  print("Nothing to reboot.")
  return
end

if not yes then
  write("Reboot them all? (y/n) ")
  local answer = read()
  if answer:lower() ~= "y" then
    print("Cancelled.")
    return
  end
end

local done, failed = 0, 0
for _, name in ipairs(targets) do
  local okOn, on = pcall(peripheral.call, name, "isOn")
  local method = (okOn and on == false) and "turnOn" or "reboot"
  local ok, err = pcall(peripheral.call, name, method)
  if ok then
    done = done + 1
    print((method == "turnOn" and "Turned on " or "Rebooted ") .. name)
  else
    failed = failed + 1
    printError(name .. ": " .. tostring(err))
  end
end
print(done .. " rebooted" .. (failed > 0 and (", " .. failed .. " failed") or ""))

if not keepSelf then
  print("Rebooting this turtle...")
  sleep(1)
  os.reboot()
end
