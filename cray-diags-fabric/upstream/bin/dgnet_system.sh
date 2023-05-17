#!/bin/sh

# custom dgnet script to run bisection test on the whole of a Bards Peak system
export FI_CXI_ATS=0

ppn=16
seconds=60
mem=$((1024 * 1024))

srunline="srun --mpi=cray_shasta"
cmdline="dgnettest -m $mem -t $seconds -r auto"
mkdir -p logs

${srunline} --ntasks-per-node=$ppn --cpu_bind=rank ${cmdline} -p $ppn -s 65536 -e bisec | tee logs/system

