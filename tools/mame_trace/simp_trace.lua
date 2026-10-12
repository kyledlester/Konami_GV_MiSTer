-- Simpsons Bowling first-boot tracer: flash glue (0x1F680080-8F), trackball (0x1F6800C0-C9),
-- GP1 display, periodic snapshots. Output dir from env SIMP_OUT.
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local dir = os.getenv("SIMP_OUT")
local log = io.open(dir .. "/flash.log", "w")
local sum = io.open(dir .. "/summary.log", "w")
local function t() return m.time:as_double() end

local st = { fw = 0, fr = 0, cmd = {}, tb = 0, lastsec = -1, prog = 0, erase = 0, ids = 0 }
local seq = {}   -- recent data-port writes (offset 0) for command decode

local function note(s)
  log:write(string.format("%9.4f %s\n", t(), s)); log:flush()
end

_G.ftap_w = sp:install_write_tap(0x1f680080, 0x1f68008f, "flash_w", function(o, d, msk)
  st.fw = st.fw + 1
  local reg = (o - 0x1f680080)
  local v = d
  if msk == 0xffff0000 then v = d >> 16; reg = reg + 2 end
  v = v & 0xffff
  if reg == 0 then
    seq[#seq + 1] = v
    if #seq > 6 then table.remove(seq, 1) end
    local lo = v & 0xff
    if lo == 0x30 or lo == 0x10 then
      if #seq >= 6 and (seq[#seq - 1] & 0xff) == 0x55 and (seq[#seq - 3] & 0xff) == 0x80 then
        st.erase = st.erase + 1
        if st.erase <= 40 then note(string.format("ERASE cmd %04X", v)) end
      end
    end
    if #seq >= 2 and (seq[#seq - 1] & 0xff) == 0xA0 then st.prog = st.prog + 1 end
    if (v & 0xff) == 0x90 then st.ids = st.ids + 1; if st.ids <= 10 then note(string.format("ID cmd %04X", v)) end end
  elseif st.fw < 400 then
    note(string.format("addr reg %X <= %04X", reg, v))
  end
end)
_G.ftap_r = sp:install_read_tap(0x1f680080, 0x1f68008f, "flash_r", function(o, d, msk)
  st.fr = st.fr + 1
end)
_G.ttap = sp:install_read_tap(0x1f6800c0, 0x1f6800cf, "tball_r", function(o, d, msk)
  st.tb = st.tb + 1
  if st.tb <= 20 then note(string.format("TB read %08X mask %08X data %08X", o, msk, d)) end
end)
_G.gtap = sp:install_write_tap(0x1f801814, 0x1f801817, "gp1", function(o, d, msk)
  local c = (d >> 24) & 0xff
  if c == 0x07 or c == 0x08 or c == 0x03 then note(string.format("GP1 %08X", d)) end
end)

local shots = {}
for s = 5, 900, 5 do shots[#shots + 1] = s end
local si = 1
_G.fsub = emu.add_machine_frame_notifier(function()
  local now = t()
  local sec = math.floor(now)
  if sec ~= st.lastsec then
    st.lastsec = sec
    sum:write(string.format("t=%4d flash_w=%d flash_r=%d prog=%d erase=%d tb_reads=%d\n",
      sec, st.fw, st.fr, st.prog, st.erase, st.tb)); sum:flush()
  end
  if si <= #shots and now >= shots[si] then
    m.video:snapshot()
    si = si + 1
  end
end)
