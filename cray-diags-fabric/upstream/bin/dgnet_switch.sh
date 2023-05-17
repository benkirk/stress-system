#!/bin/sh

# custom dgnet script to run per-switch bisection test on Bards Peak nodes
export FI_CXI_ATS=0

ppn=8
seconds=10
mem=$((1024 * 1024))

srunline="srun --ntasks-per-node=$ppn --mpi=cray_shasta"
cmdline="dgnettest -p $ppn -m $mem -t $seconds -r auto"
mkdir -p logs

bards_peak_base=(48 16 0 32)

for nic in 0 1 2 3
do
   base=${bards_peak_base[$nic]}
   top=$((base+ppn-1))
   cpubind="--cpu_bind=map_cpu:`seq -s',' $base 1 $top`"
   MPICH_OFI_NUM_NICS="1:${nic}" ${srunline} ${cpubind} ${cmdline} -N ${nic} -s 16 bisec | tee logs/switch.$nic
done

