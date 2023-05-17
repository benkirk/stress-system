#!/bin/sh

# custom dgnet script to run per-group bisection test on Bards Peak nodes
export FI_CXI_ATS=0

ppn=8
seconds=30
mem=$((1024 * 1024))

srunline="srun --mpi=cray_shasta"
cmdline="dgnettest -m $mem -t $seconds -r auto"
mkdir -p logs

bards_peak_base=(48 16 0 32)

for nic in 0 1 2 3
do
   base=${bards_peak_base[$nic]}
   top=$((base+ppn-1))
   cpubind="--cpu_bind=map_cpu:`seq -s',' $base 1 $top`"
   MPICH_OFI_NUM_NICS="1:${nic}" ${srunline} --ntasks-per-node=$ppn ${cpubind} ${cmdline} -p $ppn -N ${nic} -s 512 -e bisec | tee logs/group.$nic
done

ppn=32
${srunline} --ntasks-per-node=$ppn --cpu_bind=rank ${cmdline} -p $ppn -s 512 -e bisec | tee logs/group

