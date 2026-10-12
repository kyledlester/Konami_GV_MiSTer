#!/bin/sh
# Konami GV regression: re-analyses all GV RTL + benches with NVC and runs every test.
#
#   sim_gv/run_gv_regression.sh <workdir> <vectors-dir>
#
# <vectors-dir> = output root of tools/gv_trace_replay.py (replay/, ee/, cdda/). The vectors are
# derived from the user's own MAME trace and disc image and are never committed.
# Prints one PASS/FAIL line per bench and an overall result.
set -u
WORK=${1:?workdir}
VEC=${2:?vectors dir}
R=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$WORK" && cd "$WORK" || exit 1
rm -rf gv mem
NVC="nvc --std=2008 -L."
$NVC --work=mem -a --relaxed "$R/rtl/SyncRam.vhd" "$R/rtl/SyncFifo.vhd" "$R/rtl/SyncFifoFallThrough.vhd" \
  "$R/sim_gv/RamMLAB_stub.vhd" "$R/rtl/SyncFifoFallThroughMLAB.vhd" || exit 1
$NVC --work=gv -a --relaxed \
  "$R/rtl/gv/gv_scsi_pkg.vhd" "$R/rtl/gv/gv_lba2msf.vhd" "$R/rtl/gv/gv_eeprom93c46.vhd" \
  "$R/rtl/gv/gv_ncr53cf96.vhd" "$R/rtl/gv/gv_scsi_cdrom.vhd" "$R/rtl/gv/gv_cd_media.vhd" \
  "$R/rtl/gv/gv_cdda.vhd" "$R/rtl/gv/gv_board.vhd" "$R/rtl/gv/gv_simpbowl.vhd" "$R/rtl/dma.vhd" \
  "$R/rtl/memorymux.vhd" \
  "$R/sim_gv/tb_gv_replay.vhd" "$R/sim_gv/tb_gv_cdda.vhd" "$R/sim_gv/tb_gv_dma5.vhd" \
  "$R/sim_gv/tb_gv_memmux.vhd" "$R/sim_gv/tb_gv_eeprom.vhd" "$R/sim_gv/tb_gv_simpbowl.vhd" "$R/sim_gv/tb_gv_cdmedia.vhd" || exit 1

fail=0
run() {
  name=$1; shift
  res=$($NVC --work=gv -H 2g -e "$@" -r 2>&1 | grep -E "SUMMARY|RESULT" | tr '\n' ' ')
  echo "$name: $res"
  case "$res" in *"RESULT: PASS"*) ;; *) fail=1 ;; esac
}
run "scsi trace replay (MAME)"      tb_gv_replay -gVEC="$VEC/replay/"
run "eeprom trace replay (MAME)"    tb_gv_replay -gVEC="$VEC/ee/" -gEE_INIT=true
run "cdda bit-exact"                tb_gv_cdda   -gVEC="$VEC/cdda/"
run "dma ch5 + psx dma engine"      tb_gv_dma5   -gVEC="$VEC/replay/"
if [ -d "$VEC/../vec_cooked/replay" ]; then
  run "dma ch5, cooked MODE1 CHD"    tb_gv_dma5   -gVEC="$VEC/../vec_cooked/replay/" -gCOOKED=true
fi
run "cpu -> memorymux -> gv_board"  tb_gv_memmux
run "93c46 write path"              tb_gv_eeprom
run "cd frame layouts (MODE1/MODE1_RAW/MODE2_RAW)" tb_gv_cdmedia
if [ -f "$VEC/simpbowl/flash_events.txt" ]; then
  run "simpbowl flash replay (MAME)"  tb_gv_simpbowl -gEVENTS="$VEC/simpbowl/flash_events.txt"
fi
if [ -d "$VEC/simpbowl/replay" ]; then
  run "simpbowl scsi replay, MODE2_RAW disc (MAME)" tb_gv_replay -gVEC="$VEC/simpbowl/replay/"
fi
if [ $fail = 0 ]; then echo "REGRESSION: PASS"; else echo "REGRESSION: FAIL"; fi
exit $fail
