#!/bin/sh
# usage: run_trace.sh <runname> <seconds> [video:none|gdi] [nvram_dir_name]
# env passthrough: TRACE_PLAY=1 TRACE_PLAY_T=120 TRACE_SNAP=1
# Every run uses private nvram/cfg/snapshot/diff dirs under traces/susume/run/, so the
# user's real MAME nvram/cfg is never touched. A fresh (non-existent/empty) nvram dir means
# MAME loads the default EEPROM image from the ROM set (susume.25c).
set -e
T=${TRACE_ROOT:-$PWD/traces/susume}
RUN=$1; SECS=$2; VIDEO=${3:-none}; NV=${4:-nv_$1}
mkdir -p "$T/logs/$RUN" "$T/run/$NV" "$T/run/cfg_$RUN" "$T/snap" "$T/run/diff"
cd "${MAME_DIR:?set MAME_DIR to your MAME 0.289 folder}"
TRACE_OUT="$T/logs/$RUN" ./mame.exe susume -rompath roms \
  -autoboot_script "$T/scripts/susume_trace.lua" -autoboot_delay 0 \
  -video "$VIDEO" -sound none -nothrottle -window -skip_gameinfo -seconds_to_run "$SECS" \
  -nvram_directory "$T/run/$NV" -cfg_directory "$T/run/cfg_$RUN" \
  -snapshot_directory "$T/snap" -diff_directory "$T/run/diff" 2>&1 | tail -3
