-- susume_trace.lua : MAME 0.289 Lua tracer for Konami GV "susume"
-- Env vars:
--   TRACE_OUT   output directory for logs (must exist)
--   TRACE_PLAY  if "1": insert coin at PLAY_T (default 120 s), press start, then play inputs
--   TRACE_SNAP  if "1": take snapshots at fixed emulated times (needs video enabled)
-- All logs: columns  time_s frame PC addr R/W mask data  [decoded]
local OUT = os.getenv("TRACE_OUT") or "traces/logs/tmp"
local PLAY = os.getenv("TRACE_PLAY") == "1"
local PLAY_T = tonumber(os.getenv("TRACE_PLAY_T") or "120")
local SNAP = os.getenv("TRACE_SNAP") == "1"

local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local sp = cpu.spaces["program"]
local screen = machine.screens[":screen"]
local pcst = cpu.state["CURPC"]

G = { taps = {}, files = {}, cnt = {}, internal = false }

local function f(name)
  local h = G.files[name]
  if not h then
    h = io.open(OUT .. "/" .. name, "w")
    G.files[name] = h
  end
  return h
end
local function now() return machine.time:as_double() end
local function frame() return screen:frame_number() end
local function pc() return pcst.value end
local function hdr(addr, rw, mask, data)
  return string.format("%.6f %6d %08x %08x %s %08x %08x", now(), frame(), pc(), addr, rw, mask, data)
end
local function cnt(k) G.cnt[k] = (G.cnt[k] or 0) + 1 return G.cnt[k] end
local function milestone(msg)
  f("milestones.log"):write(string.format("%.6f %6d %08x %s\n", now(), frame(), pc(), msg))
end

---------------------------------------------------------------- CRC32
local CRCT = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  CRCT[i] = c
end
local function crc_ram(addr, nbytes)
  local c = 0xFFFFFFFF
  local first = {}
  G.internal = true
  for a = addr, addr + nbytes - 1, 4 do
    local w = sp:read_u32(a & 0x1ffffc)
    for s = 0, 24, 8 do
      local b = (w >> s) & 0xff
      if #first < 64 then first[#first + 1] = string.format("%02x", b) end
      c = CRCT[(c ~ b) & 0xff] ~ (c >> 8)
    end
  end
  G.internal = false
  return c ~ 0xFFFFFFFF, table.concat(first, " ")
end

---------------------------------------------------------------- NCR 53CF96
local NCR_R = { [0]="TCOUNT0","TCOUNT1","FIFO","COMMAND","STATUS","ISTATUS","SEQSTEP","FIFO_FLAGS",
  "CONF1","CLOCK_CONV?","TEST?","CONF2","CONF3","CONF4","TCOUNT2","FIFO_BOTTOM?" }
local NCR_W = { [0]="TCOUNT0","TCOUNT1","FIFO","COMMAND","BUSID","TIMEOUT","SYNC_PERIOD","SYNC_OFFSET",
  "CONF1","CLOCK_CONV","TEST","CONF2","CONF3","CONF4","TCOUNT2","FIFO_ALIGN" }
local NCR_CMD = { [0x00]="NOP",[0x01]="FLUSH_FIFO",[0x02]="RESET_CHIP",[0x03]="RESET_BUS",
  [0x10]="XFER_INFO",[0x11]="INIT_CMD_COMPLETE",[0x12]="MSG_ACCEPTED",[0x18]="XFER_PAD",[0x1a]="SET_ATN",[0x1b]="RESET_ATN",
  [0x40]="RESELECT",[0x41]="SELECT_NO_ATN",[0x42]="SELECT_ATN",[0x43]="SELECT_ATN_STOP",[0x44]="ENABLE_SEL",[0x45]="DISABLE_SEL",[0x46]="SELECT_ATN3" }
local PHASE = { [0]="DATA_OUT","DATA_IN","COMMAND","STATUS","rsv4","rsv5","MSG_OUT","MSG_IN" }
local function ncr_cmd_name(v)
  local n = NCR_CMD[v & 0x7f] or string.format("?%02x", v & 0x7f)
  if v & 0x80 ~= 0 then n = "DMA|" .. n end
  return n
end

-- DMA ch5 state
local dma = { madr = 0, bcr = 0, chcr = 0, pending = nil, nxfer = 0, ncrc = 0, last_chcr_rd = -1 }
local ncr = { fifo = {}, last_cdb = "", dma_cmd_seen = false }

local function dma_check_crc(why)
  local p = dma.pending
  if p and p.armed then
    dma.ncrc = dma.ncrc + 1
    local nbytes = p.words * 4
    local c, first = crc_ram(p.addr, nbytes)
    local line = string.format("%.6f %6d CRC xfer#%d addr=%06x bytes=%d crc32=%08x first64=[%s] cdb=[%s] at=%s",
      now(), frame(), p.n, p.addr, nbytes, c, first, p.cdb, why)
    -- per-2048 sector CRCs
    if nbytes >= 2048 and nbytes % 2048 == 0 and dma.ncrc <= 40 then
      local parts = {}
      for s = 0, nbytes // 2048 - 1 do
        local cs = crc_ram(p.addr + s * 2048, 2048)
        parts[#parts + 1] = string.format("%08x", cs)
        if s >= 31 then parts[#parts + 1] = "..." break end
      end
      line = line .. " sector_crcs=" .. table.concat(parts, ",")
    end
    f("dma5.log"):write(line .. "\n")
    dma.pending = nil
  end
end

local function ncr_access(addr, rw, mask, data)
  local base = addr - 0x1f000000
  for lane = 0, 2, 2 do
    local lm = 0xff << (lane * 8)
    if mask & lm ~= 0 then
      local reg = base // 2 + lane // 2
      local v = (data >> (lane * 8)) & 0xff
      local name = (rw == "R") and (NCR_R[reg] or "?") or (NCR_W[reg] or "?")
      local extra = ""
      if rw == "W" then
        if reg == 2 then ncr.fifo[#ncr.fifo + 1] = v end
        if reg == 3 then
          extra = ncr_cmd_name(v)
          local c = v & 0x7f
          if c == 0x41 or c == 0x42 or c == 0x43 or c == 0x46 then
            local t = {}
            for _, b in ipairs(ncr.fifo) do t[#t + 1] = string.format("%02x", b) end
            ncr.last_cdb = table.concat(t, " ")
            extra = extra .. " fifo=[" .. ncr.last_cdb .. "]"
            if cnt("first_select") == 1 then milestone("first SCSI select cdb=" .. ncr.last_cdb) end
          end
          if c == 0x01 or c == 0x02 or c == 0x41 or c == 0x42 or c == 0x43 or c == 0x46 then ncr.fifo = {} end
          if c == 0x41 or c == 0x42 or c == 0x43 or c == 0x46 then ncr.dma_cmd_since_select = false end
          if c == 0x10 and v & 0x80 ~= 0 then
            ncr.dma_cmd_seen = true
            ncr.dma_cmd_since_select = true
            if dma.pending then dma.pending.armed_cmd = true end
          elseif dma.pending and dma.pending.armed_cmd then
            dma.pending.armed = true
            dma_check_crc("next NCR cmd " .. extra)
          end
        end
      else
        if reg == 4 then extra = string.format("phase=%s%s%s%s%s", PHASE[v & 7], (v & 0x80 ~= 0) and " INT" or "",
            (v & 0x40 ~= 0) and " GE" or "", (v & 0x20 ~= 0) and " PE" or "", (v & 0x10 ~= 0) and " TC" or "") end
        if reg == 5 then
          local t = {}
          if v & 0x80 ~= 0 then t[#t+1] = "SCSI_RST" end
          if v & 0x40 ~= 0 then t[#t+1] = "ILL_CMD" end
          if v & 0x20 ~= 0 then t[#t+1] = "DISC" end
          if v & 0x10 ~= 0 then t[#t+1] = "BUS_SVC" end
          if v & 0x08 ~= 0 then t[#t+1] = "FUNC_CMP" end
          if v & 0x04 ~= 0 then t[#t+1] = "RESEL" end
          if v & 0x02 ~= 0 then t[#t+1] = "SEL_ATN" end
          if v & 0x01 ~= 0 then t[#t+1] = "SEL" end
          G.internal = true
          local ist = sp:read_u32(0x1f801070)
          G.internal = false
          extra = table.concat(t, "|") .. string.format(" (I_STAT=%04x irq10=%d)", ist & 0xffff, (ist >> 10) & 1)
        end
        if reg == 6 then extra = string.format("seqstep=%d", v & 7) end
        if reg == 7 then extra = string.format("fifo_count=%d", v & 0x1f) end
      end
      f("ncr.log"):write(string.format("%s reg=%X %-12s val=%02x %s\n", hdr(addr, rw, mask, data), reg, name, v, extra))
      cnt("ncr_" .. rw)
    end
  end
end

---------------------------------------------------------------- EEPROM / inputs
local ee = { cs = 0, last = -1 }
local inp = {}
local function input_access(addr, mask, data)
  local key = string.format("%08x/%08x", addr, mask)
  local e = inp[key]
  if not e then e = { n = 0, last = nil, samples = 0 } inp[key] = e end
  e.n = e.n + 1
  if e.last ~= data and e.samples < 40 then
    e.samples = e.samples + 1
    f("inputs.log"):write(hdr(addr, "R", mask, data) .. "\n")
  end
  e.last = data
  -- eeprom DO is P1 bit 13 (lane 1)
  if addr == 0x1f100000 and (mask & 0x2000) ~= 0 and ee.cs == 1 then
    local d = (data >> 13) & 1
    if ee.lastdo == d then
      ee.rep = (ee.rep or 0) + 1
    else
      if (ee.rep or 0) > 0 then f("eeprom.log"):write(string.format("   (previous DO read repeated %d more times)\n", ee.rep)) end
      ee.rep = 0
      f("eeprom.log"):write(string.format("%s DO=%d\n", hdr(addr, "R", mask, data), d))
    end
    ee.lastdo = d
  end
end
local function eeprom_write(addr, mask, data)
  local v = data & 0xff
  ee.cs = (v >> 1) & 1
  if (ee.rep or 0) > 0 then f("eeprom.log"):write(string.format("   (previous DO read repeated %d more times)\n", ee.rep)) end
  ee.rep = 0
  ee.lastdo = nil
  if v ~= ee.last then
    f("eeprom.log"):write(string.format("%s DI=%d CS=%d CLK=%d\n", hdr(addr, "W", mask, data), v & 1, (v >> 1) & 1, (v >> 2) & 1))
  end
  ee.last = v
  cnt("ee_w")
end

---------------------------------------------------------------- MB89371 / misc / watchdog
local wd = { n = 0, first = nil, last = nil, vals = {}, gaps = {} }
local function mb_access(addr, rw, mask, data)
  local base = addr - 0x1f680000
  local parts = {}
  for lane = 0, 2, 2 do
    if mask & (0xff << (lane * 8)) ~= 0 then
      local ch = base // 8
      local off = ((base % 8) // 4) * 2 + lane // 2
      local rn = ({ [0]="DATA","STATUS/CTRL","BAUD","MODE" })[off]
      parts[#parts + 1] = string.format("ch%d off%d %s=%02x", ch, off, rn, (data >> (lane * 8)) & 0xff)
    end
  end
  f("mb89371_misc.log"):write(hdr(addr, rw, mask, data) .. " MB89371 " .. table.concat(parts, "; ") .. "\n")
end
local function wd_write(addr, mask, data)
  local t = now()
  wd.n = wd.n + 1
  if wd.last then
    local g = math.floor((t - wd.last) * 1e6 + 0.5)
    local b = g < 1000 and "<1ms" or (g < 10000 and "1-10ms" or (g < 20000 and "10-20ms" or (g < 40000 and "20-40ms" or ">=40ms")))
    wd.gaps[b] = (wd.gaps[b] or 0) + 1
  else
    wd.first = t
  end
  wd.last = t
  local k = string.format("%08x@%08x pc=%08x", data, mask, pc())
  wd.range = wd.range or {}
  if not wd.range[k] then wd.range[k] = { t } end
  wd.range[k][2] = t
  wd.vals[k] = (wd.vals[k] or 0) + 1
  if wd.n <= 20 then f("watchdog.log"):write(hdr(addr, "W", mask, data) .. "\n") end
end

local function exp_access(addr, rw, mask, data)
  if G.internal then return end
  if addr >= 0x1f000000 and addr <= 0x1f00001f then ncr_access(addr, rw, mask, data)
  elseif addr >= 0x1f100000 and addr <= 0x1f10000b and rw == "R" then input_access(addr, mask, data)
  elseif addr >= 0x1f180000 and addr <= 0x1f180003 and rw == "W" then eeprom_write(addr, mask, data)
  elseif addr >= 0x1f680000 and addr <= 0x1f68000f then mb_access(addr, rw, mask, data)
  elseif addr >= 0x1f780000 and addr <= 0x1f780003 and rw == "W" then wd_write(addr, mask, data)
  else
    local n = cnt("other_" .. string.format("%08x", addr))
    if n <= 50 then
      f("mb89371_misc.log"):write(hdr(addr, rw, mask, data) .. " OTHER/UNMAPPED\n")
    end
    if cnt("other_any") == 1 then milestone(string.format("first OTHER exp access %08x %s", addr, rw)) end
  end
end

---------------------------------------------------------------- DMA ch5 / DPCR / DICR
local DMA_NAMES = { [0x1f8010d0]="D5_MADR",[0x1f8010d4]="D5_BCR",[0x1f8010d8]="D5_CHCR",[0x1f8010dc]="D5_?",
  [0x1f8010f0]="DPCR",[0x1f8010f4]="DICR" }
local function dma_access(addr, rw, mask, data)
  if G.internal then return end
  local name = DMA_NAMES[addr] or "?"
  if rw == "R" then
    cnt("dma_r_" .. name)
    if addr == 0x1f8010d8 then
      local busy = (data >> 24) & 1
      if busy ~= dma.last_chcr_rd then
        f("dma5.log"):write(string.format("%s %s busy=%d\n", hdr(addr, rw, mask, data), name, busy))
        dma.last_chcr_rd = busy
      end
    elseif addr == 0x1f8010f4 then
      -- log DICR reads only when ch5 flag (bit 29) set, deduped
      local fl = (data >> 29) & 1
      if fl ~= (dma.last_dicr_fl or -1) then
        f("dma5.log"):write(string.format("%s %s ch5flag=%d master=%d\n", hdr(addr, rw, mask, data), name, fl, (data >> 31) & 1))
        dma.last_dicr_fl = fl
      end
    end
    return
  end
  local extra = ""
  if addr == 0x1f8010d0 then dma.madr = data & 0xffffff
  elseif addr == 0x1f8010d4 then dma.bcr = data
    extra = string.format("bs=%d ba=%d", data & 0xffff, data >> 16)
  elseif addr == 0x1f8010d8 then
    dma.chcr = data
    extra = string.format("dir=%s step=%s mode=%d start=%d trig=%d", (data & 1 == 1) and "fromRAM" or "toRAM",
      (data & 2 ~= 0) and "-4" or "+4", (data >> 9) & 3, (data >> 24) & 1, (data >> 28) & 1)
    if (data >> 24) & 1 == 1 then
      dma.nxfer = dma.nxfer + 1
      local bs, ba = dma.bcr & 0xffff, dma.bcr >> 16
      if bs == 0 then bs = 0x10000 end
      local words = ((data >> 9) & 3) == 1 and bs * math.max(ba, 1) or bs
      extra = extra .. string.format(" XFER#%d addr=%06x words=%d bytes=%d last_cdb=[%s]", dma.nxfer, dma.madr, words, words * 4, ncr.last_cdb)
      if dma.nxfer == 1 then milestone("first DMA5 start " .. extra) end
      if data & 1 == 1 then
        local nb = math.min(words * 4, 4096)
        local c, first = crc_ram(dma.madr & 0x1ffffc, nb)
        f("dma5.log"):write(string.format("%.6f %6d OUTDATA xfer#%d addr=%06x bytes=%d crc32=%08x bytes=[%s] cdb=[%s]\n",
          now(), frame(), dma.nxfer, dma.madr & 0x1ffffc, words * 4, c, first, ncr.last_cdb))
      end
      if data & 1 == 0 then
        dma.pending = { addr = dma.madr & 0x1ffffc, words = words, n = dma.nxfer, cdb = ncr.last_cdb,
          armed_cmd = ncr.dma_cmd_since_select or false }
      end
    end
  end
  if addr == 0x1f8010f0 or addr == 0x1f8010f4 then
    local n = cnt("dma_w_" .. name)
    if dma["lastw" .. addr] == data and n > 10 then return end
    dma["lastw" .. addr] = data
  end
  f("dma5.log"):write(string.format("%s %s %s\n", hdr(addr, rw, mask, data), name, extra))
end

---------------------------------------------------------------- IRQ controller
local irq = { last_b10 = -1, nread = 0 }
local function irq_access(addr, rw, mask, data)
  if G.internal then return end
  if addr == 0x1f801070 then
    if rw == "R" then
      irq.nread = irq.nread + 1
      local b = (data >> 10) & 1
      if b ~= irq.last_b10 then
        f("irq.log"):write(string.format("%s I_STAT read bit10=%d\n", hdr(addr, rw, mask, data), b))
        irq.last_b10 = b
      end
    else
      cnt("istat_w")
      if (data >> 10) & 1 == 0 then
        f("irq.log"):write(string.format("%s I_STAT write (acks bit10%s)\n", hdr(addr, rw, mask, data),
          (data & 0xffff) == 0xfbff and " only" or " + others"))
        cnt("istat_ack10")
      end
    end
  elseif addr == 0x1f801074 then
    if rw == "W" then
      local n = cnt("imask_w")
      irq.seen_mask = irq.seen_mask or {}
      if n <= 40 or not irq.seen_mask[data] then
        f("irq.log"):write(string.format("%s I_MASK write irq10_en=%d%s\n", hdr(addr, rw, mask, data), (data >> 10) & 1, n > 40 and " (new value)" or ""))
      end
      irq.seen_mask[data] = true
    else
      cnt("imask_r")
    end
  end
end

---------------------------------------------------------------- GPU GP1
local gp1 = { cnt = {}, seen05 = {}, n05 = 0, last = {} }
local function gp1_write(addr, mask, data)
  local c = data >> 24
  gp1.cnt[c] = (gp1.cnt[c] or 0) + 1
  local extra = ""
  if c == 0x08 then
    local hr = ({ [0]=256, 320, 512, 640 })[data & 3]
    if data & 0x40 ~= 0 then hr = 368 end
    extra = string.format("DISPLAY_MODE w=%d vres=%s video=%s depth=%s interlace=%d", hr,
      (data & 4 ~= 0) and "480" or "240", (data & 8 ~= 0) and "PAL" or "NTSC", (data & 0x10 ~= 0) and "24bpp" or "15bpp", (data >> 5) & 1)
  elseif c == 0x05 then extra = string.format("DISPLAY_START x=%d y=%d", data & 0x3ff, (data >> 10) & 0x1ff)
  elseif c == 0x06 then extra = string.format("H_RANGE x1=%d x2=%d", data & 0xfff, (data >> 12) & 0xfff)
  elseif c == 0x07 then extra = string.format("V_RANGE y1=%d y2=%d", data & 0x3ff, (data >> 10) & 0x3ff)
  elseif c == 0x03 then extra = string.format("DISPLAY_ENABLE %s", (data & 1 == 0) and "on" or "off")
  elseif c == 0x04 then extra = string.format("DMA_DIR %d", data & 3)
  elseif c == 0x00 then extra = "RESET_GPU"
  elseif c == 0x01 then extra = "RESET_CMDBUF"
  elseif c == 0x02 then extra = "ACK_IRQ"
  elseif c >= 0x10 and c <= 0x1f then extra = string.format("GET_INFO %x", data & 0xf)
  end
  local log = true
  if c == 0x05 then
    gp1.n05 = gp1.n05 + 1
    if gp1.n05 > 30 and gp1.seen05[data] then log = false end
    gp1.seen05[data] = true
  elseif c == 0x04 or (c >= 0x10 and c <= 0x1f) or c == 0x01 or c == 0x02 then
    -- floods: log only when different from the previous same-command value, first 30
    gp1.seen = gp1.seen or {}
    if (gp1.cnt[c] > 30) and gp1.seen[data] then log = false end
    gp1.seen[data] = true
  elseif c == 0x06 or c == 0x07 or c == 0x08 or c == 0x03 then
    if gp1.cnt[c] > 10 and gp1.last[c] == data then log = false end
  end
  if c == 0x08 and gp1.last[c] ~= data then milestone("GP1 " .. extra) end
  gp1.last[c] = data
  if log then f("gpu_gp1.log"):write(string.format("%s GP1 %02x %s\n", hdr(addr, "W", mask, data), c, extra)) end
end

---------------------------------------------------------------- SPU
local spu_last = {}
local SPU_N = { [0x1f801da8]="SPUCNT(1DAA hi)", [0x1f801db0]="CDVOL L/R(1DB0/1DB2)", [0x1f801db4]="EXTVOL L/R(1DB4/1DB6)" }
local function spu_write(addr, mask, data)
  -- 1DAA is the upper halfword of the 1DA8 word
  local key = addr .. ":" .. mask
  cnt("spu_w")
  if spu_last[key] == data then return end
  spu_last[key] = data
  local extra = ""
  if addr == 0x1f801da8 and mask & 0xffff0000 ~= 0 then
    local v = data >> 16
    extra = string.format("SPUCNT=%04x enable=%d unmute=%d cd_audio_en=%d ext_en=%d cd_reverb=%d", v, (v >> 15) & 1, (v >> 14) & 1, v & 1, (v >> 1) & 1, (v >> 2) & 1)
  elseif addr == 0x1f801db0 then
    if mask & 0xffff ~= 0 then extra = extra .. string.format("CDVOL_L=%04x ", data & 0xffff) end
    if mask & 0xffff0000 ~= 0 then extra = extra .. string.format("CDVOL_R=%04x", data >> 16) end
  elseif addr == 0x1f801db4 then
    if mask & 0xffff ~= 0 then extra = extra .. string.format("EXTVOL_L=%04x ", data & 0xffff) end
    if mask & 0xffff0000 ~= 0 then extra = extra .. string.format("EXTVOL_R=%04x", data >> 16) end
  elseif addr == 0x1f801d80 then
    if mask & 0xffff ~= 0 then extra = extra .. string.format("MVOL_L=%04x ", data & 0xffff) end
    if mask & 0xffff0000 ~= 0 then extra = extra .. string.format("MVOL_R=%04x", data >> 16) end
  else
    return
  end
  f("spu.log"):write(string.format("%s %s\n", hdr(addr, "W", mask, data), extra))
end

---------------------------------------------------------------- MEMCTRL
local MC = { [0x1f801000]="EXP1_BASE",[0x1f801004]="EXP2_BASE",[0x1f801008]="EXP1_DELAY_SIZE",[0x1f80100c]="EXP3_DELAY_SIZE",
  [0x1f801010]="BIOS_DELAY_SIZE",[0x1f801014]="SPU_DELAY",[0x1f801018]="CDROM_DELAY",[0x1f80101c]="EXP2_DELAY_SIZE",[0x1f801020]="COM_DELAY",[0x1f801060]="RAM_SIZE" }
local function memctrl_access(addr, rw, mask, data)
  if G.internal then return end
  if rw == "R" then cnt("memctrl_r") return end
  local extra = ""
  if addr ~= 0x1f801000 and addr ~= 0x1f801004 and addr ~= 0x1f801020 and addr ~= 0x1f801060 then
    extra = string.format("wr_delay=%d rd_delay=%d recovery=%d hold=%d float=%d pre=%d bus16=%d size=2^%d", data & 0xf, (data >> 4) & 0xf,
      (data >> 8) & 1, (data >> 9) & 1, (data >> 10) & 1, (data >> 11) & 1, (data >> 12) & 1, (data >> 16) & 0x1f)
  end
  f("memctrl.log"):write(string.format("%s %s %s\n", hdr(addr, rw, mask, data), MC[addr] or "?", extra))
end

---------------------------------------------------------------- install taps
local function T(a, b, name, fn)
  G.taps[#G.taps + 1] = sp:install_read_tap(a, b, name .. "_r", function(o, d, m) fn(o, "R", m, d) end)
  G.taps[#G.taps + 1] = sp:install_write_tap(a, b, name .. "_w", function(o, d, m) fn(o, "W", m, d) end)
end
T(0x1f000000, 0x1f7fffff, "exp", exp_access)
T(0x1f801000, 0x1f801023, "memctrl", memctrl_access)
T(0x1f801060, 0x1f801063, "ramsize", memctrl_access)
T(0x1f801070, 0x1f801077, "irq", irq_access)
T(0x1f8010d0, 0x1f8010df, "dma5", dma_access)
T(0x1f8010f0, 0x1f8010f7, "dmactl", dma_access)
G.taps[#G.taps + 1] = sp:install_write_tap(0x1f801814, 0x1f801817, "gp1", function(o, d, m) if not G.internal then gp1_write(o, m, d) end end)
G.taps[#G.taps + 1] = sp:install_write_tap(0x1f801d80, 0x1f801dbf, "spu", function(o, d, m) spu_write(o, m, d) end)


---------------------------------------------------------------- per-frame: inputs, snapshots, flush, resolution
local snaps = { 5, 10, 15, 20, 30, 45, 60, 90, 120, 125, 130, 140, 150, 175 }
local snap_i = 1
local function sres()
  local w, h = screen.width, screen.height
  local ok, va = pcall(function() return screen.visible_area end)
  local vs = ""
  if ok and va then vs = string.format(" visarea=%d..%d x %d..%d", va.min_x, va.max_x, va.min_y, va.max_y) end
  local ok2, rr = pcall(function() return screen.refresh end)
  return string.format("%dx%d%s refresh=%s", w, h, vs, ok2 and tostring(rr) or "?")
end

local play_events = {}
if PLAY then
  local function ev(t, port, field, v) play_events[#play_events + 1] = { t = t, port = port, field = field, v = v } end
  local t0 = PLAY_T
  ev(t0 + 0.0, ":P1", "Coin 1", 1) ev(t0 + 0.2, ":P1", "Coin 1", 0)
  ev(t0 + 1.0, ":P1", "Coin 1", 1) ev(t0 + 1.2, ":P1", "Coin 1", 0)
  for _, ts in ipairs({ 3.0, 5.0, 7.0, 9.0, 11.0 }) do
    ev(t0 + ts, ":P1", "1 Player Start", 1) ev(t0 + ts + 0.4, ":P1", "1 Player Start", 0)
  end
  -- some menu confirms / gameplay presses
  local t = t0 + 13
  local seq = { "P1 Button 1", "P1 Left", "P1 Button 1", "P1 Right", "P1 Button 2", "P1 Down", "P1 Button 1", "P1 Up" }
  local i = 0
  while t < t0 + 75 do
    i = i + 1
    local fld = seq[(i - 1) % #seq + 1]
    ev(t, ":P1", fld, 1) ev(t + 0.15, ":P1", fld, 0)
    t = t + 0.7
  end
  table.sort(play_events, function(a, b) return a.t < b.t end)
end
local pe_i = 1

G.frame_sub = emu.add_machine_frame_notifier(function()
  local t = now()
  while PLAY and pe_i <= #play_events and play_events[pe_i].t <= t do
    local e = play_events[pe_i]
    local fld = machine.ioport.ports[e.port].fields[e.field]
    if e.v == 1 then fld:set_value(1) else fld:clear_value() end
    if e.field == "Coin 1" or e.field == "1 Player Start" or pe_i % 20 == 0 then
      milestone(string.format("INPUT %s %s=%d", e.port, e.field, e.v))
    end
    pe_i = pe_i + 1
  end
  if SNAP and snap_i <= #snaps and t >= snaps[snap_i] then
    machine.video:snapshot()
    milestone(string.format("SNAPSHOT %d at t=%.3f screen %s", snap_i, t, sres()))
    snap_i = snap_i + 1
  end
  local fr = frame()
  if fr % 60 == 0 then
    local r = sres()
    if r ~= G.last_res then milestone("screen res " .. r) G.last_res = r end
  end
  if fr % 300 == 0 then for _, h in pairs(G.files) do h:flush() end end
end)

milestone("trace start; OUT=" .. OUT .. " PLAY=" .. tostring(PLAY) .. " SNAP=" .. tostring(SNAP))

G.stop_sub = emu.add_machine_stop_notifier(function()
  local s = f("counts.log")
  s:write(string.format("end time %.6f frame %d\n", now(), frame()))
  local keys = {}
  for k in pairs(G.cnt) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do s:write(string.format("count %s %d\n", k, G.cnt[k])) end
  s:write(string.format("istat_reads %d\n", irq.nread))
  local ik = {}
  for k in pairs(inp) do ik[#ik + 1] = k end
  table.sort(ik)
  for _, k in ipairs(ik) do s:write(string.format("input %s reads=%d last=%08x\n", k, inp[k].n, inp[k].last or 0)) end
  s:write(string.format("watchdog writes=%d first=%.6f last=%.6f\n", wd.n, wd.first or -1, wd.last or -1))
  for k, v in pairs(wd.vals) do s:write(string.format("watchdog value %s n=%d first=%.6f last=%.6f\n", k, v, wd.range[k][1], wd.range[k][2])) end
  for k, v in pairs(wd.gaps) do s:write(string.format("watchdog gap %s n=%d\n", k, v)) end
  for c = 0, 255 do if gp1.cnt[c] then s:write(string.format("gp1 cmd %02x n=%d last=%08x\n", c, gp1.cnt[c], gp1.last[c])) end end
  s:write(string.format("dma5 xfers %d\n", dma.nxfer))
  for _, h in pairs(G.files) do h:close() end
end)
