-- Exact flash-port access log for replay: "R|W offset(hex, from 0x1F680080) mask(hex) data(hex)"
-- for every CPU access to 0x1F680080-0x1F68008F, up to MAXEV events. Holds TEST for HOLD_TEST s.
local m = manager.machine
local sp = m.devices[":maincpu"].spaces["program"]
local out = io.open(os.getenv("SIMP_OUT") .. "/flash_events.txt", "w")
local maxev = tonumber(os.getenv("MAXEV") or "3000000")
local n = 0
local function ev(rw, o, d, msk)
  if n < maxev then
    out:write(string.format("%s %02X %08X %08X %.6f\n", rw, o - 0x1f680080, msk, d, m.time:as_double()))
    n = n + 1
    if n == maxev then out:flush() end
  end
end
_G.fw = sp:install_write_tap(0x1f680080, 0x1f68008f, "fw", function(o, d, msk) ev("W", o, d, msk) end)
_G.fr = sp:install_read_tap(0x1f680080, 0x1f68008f, "fr", function(o, d, msk) ev("R", o, d, msk) end)

local hold = tonumber(os.getenv("HOLD_TEST") or "0")
local tf = nil
for _, port in pairs(m.ioport.ports) do
  for _, f in pairs(port.fields) do
    if f.type == m.ioport:token_to_input_type("SERVICE") then tf = f end
  end
end
_G.ts = emu.add_machine_frame_notifier(function()
  if tf then
    if m.time:as_double() < hold then tf:set_value(1) else tf:clear_value() end
  end
end)
