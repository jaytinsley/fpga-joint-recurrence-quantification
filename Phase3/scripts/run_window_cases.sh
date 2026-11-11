#!/bin/bash
# Run the filtered insect pairs on the board (m<=10 bitstream, DMA path), 3 windows each, then write the per-case reports.
# Run from Phase3/build:  bash ../scripts/run_filtered_pairs.sh
PY="${PY:-$(cd "$(dirname "$0")/../../Phase1" && pwd)/.venv/Scripts/python.exe}"   # override with PY=... if needed
XSDB=/c/AMDDesignTools/2026.1/Vitis/bin/xsdb.bat
VIV=/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat
cd "$(dirname "$0")/../build" || exit 1
echo "STEP load"; cmd //c "$XSDB" ../scripts/hw_load.tcl xsa_rt_m10 > hwresults/load_f.log 2>&1; tail -3 hwresults/load_f.log
for c in "$@"; do
  echo "STEP case $c"
  $PY ../scripts/gen_rt_case.py "$c" --nrep 3 > "hwresults/gen_$c.log" 2>&1 || { echo "gen failed $c"; continue; }
  cmd //c "$XSDB" ../scripts/hw_ocm_load.tcl "rtcase/$c.bin" > "hwresults/ocm_$c.log" 2>&1
  cmd //c "$VIV" -mode batch -source ../scripts/hw_rt_run.tcl -tclargs "$c" 3 > "hwresults/rtrun_$c.log" 2>&1
  grep -a "HWRUN" "hwresults/rtrun_$c.log" | tail -3
  (cd .. && $PY scripts/insect_report.py "$c" 2>&1 | tail -2)
done
echo "STEP done"
