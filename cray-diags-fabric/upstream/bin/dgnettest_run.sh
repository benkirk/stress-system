#!/bin/bash
################################################################################
# Copyright 2021 Hewlett Packard Enterprise Development LP
################################################################################

function print_help() 
{
   echo "Usage: $1 [-hdbv][-n nodelist][-s set-size][-t time][-T threshold][-m size][-i mpi-mode][-p PPN][-r repetitions][-R counter][-l latency] [all2all | bisect | latency]"
   echo "    -b            Set slurm to broadcast out dgnettest to the nodes (default is no broadcasting of files)" 
   echo "    -d            Debug"
   echo "    -c class      Set Network class type of 0-4 (default $CLASS)"
   echo "    -C            Run the test over both NICs concurrently"
   echo "                  or, if using multiple NICs and changing -p, the NICs to Ranks mapping is needed."
   echo "    -i            Ignore hostfile and MAC address errors"
   echo "    -l latency    Set the high CV threshold for the latency test. Value should be between 0 and 1, (default $CV_THRESHOLD)"
   echo "    -m size       Specify size of messages used in bytes (default $MEM)"
   echo "    -M mpi_mode   Set mpi mode for srun (default $MPI)"
   echo "    -n nodelist   Select nodes to use (default all)"
   echo "    -N NIC        Run over a single, user selected NIC (must select ${NICMIN} to ${NICMAX})"
   echo "    -p PPN        Set the number of processes per node. (default is selected by NUMA)"
   echo "    -P partition  Set the slurm partition to use while running (default is none/slurm default)"
   echo "    -r reps       Set the number of repetitions to run each test (default $REPS)" 
   echo "    -R counter    Specify a counter to sample while running dgnettest"
   echo "    -s set-size   Run tests over sets of nodes of a given size (default 512)"
   echo "    -S            Displays additional statistical information for loopback, latency, and user selected tests. Default is not to display"
   echo "    -t time       Specify runtime for each test (default $SECONDS)"
   echo "    -T threshold  Set the low bandwidth threshold. Value should be between 0 and 1, (default $THRESHOLD)"
   echo "    -v            Verbose"
   exit 1
}

function check_fw_version()
{
   re=0
   nic_min=$1
   nic_max=$2
   NODELIST=$3
   partition=$4
   
   SRUNPCIE="srun --nodelist=$NODELIST --exclusive --ntasks-per-node=1 $partition"
   result=$(${SRUNPCIE} bash -c 'ver=`cat /sys/class/cxi/cxi*/device/uc/qspi_blob_version`; host=`hostname`; echo ${host}: ${ver}')

   OLD_IFS=$IFS
   IFS=$'\n'
   fw=( $(echo "$result" | cut -d ':' -f2 | grep -e " [0-9]*.[0-9]*" | sort | uniq -c | sort -nr | sed 's/ \+/ /g') )

   if [ ${#fw[@]} -lt 1 ]; then
      #something in the run failed
      echo "failed to run firmware version check."
      re=1
   elif [ ${#fw[@]} -gt 1 ]; then
      #found some out of date FW
      let cnt=0
      ver=""
      for (( i=0; i < ${#fw[@]}; ++i)); do
         let num=`echo ${fw[i]} | cut -d' ' -f2`
         if [ $num -gt $cnt ]; then
            let cnt=$num
            ver=`echo ${fw[i]} | cut -d' ' -f3`
         fi
      done
       
      echo "There were ${#fw[@]} firmware versions found on the selected nodes."     
      echo "The most common firmware across the nodes is ${ver}($cnt nodes)."
      echo "The following nodes should have their firmware updated to match the most common version:"
      echo "${result}" | grep -v $ver
        
      re=1
   else
      #all FW matches
      ver=`echo ${fw[0]} | cut -d' ' -f3`
      echo "The firmware for all selected nodes is ${ver}"
   fi
   IFS=$OLD_IFS

   return $re
}

####
#Generates an array of sets to run dgnettest over. The table should follow the following format
# "Number of Cores" "Number of Sockets" "Number of NICs" "Number of NUMA nodes" "List of nodes fitting these parameters"  
function generate_nodelist_sets()
{
  fullnodelist=$1
  partition=$2
  nodelistsets=()

  SRUNNODES="srun --nodelist=$NODELIST --exclusive --ntasks-per-node=1 $partition"
  results=$(${SRUNNODES} bash -c 'cores=`lscpu | grep "Core(s)" | cut -d ':' -f2 | sed -E "s/ //g"`;\
           sockets=`grep physical.id /proc/cpuinfo | sort -u | wc -l`;\
           nics=`ls /sys/class/net/ | grep hsn | sort -u | wc -l`;\
           numa=`numactl --hardware | grep available | cut -d " " -f 2`;\
           if [ $? != 0 ]; then numa=-1; fi;\
           host=`hostname`;\
           echo ${host}: ${cores} ${sockets} ${nics} ${numa}')

  nodesets=( $(echo "${results}" | cut -d':' -f2 | sort -u | tr ' ' '_') )
  for nodeset in "${nodesets[@]}"; do
     searchtag=`echo "${nodeset}" | tr '_' ' '`
     nlist=`echo "${results}" | grep "${searchtag}" | cut -d':' -f1 | tr '\n' ','`
     nodelistsets+=( "${nodeset}_${nlist::-1}\n" )
  done
  
  echo "${nodelistsets[@]}"
}

OPTS=`getopt -o hbc:CdDim:M:n:N:p:P:r:R:s:St:T:v --long verbose,help,nodelist:,mpi:,ppn:,mem:,reps:,class:,bcast,data,NIC:,debug,concurrent,threshold:,stats,counter:,cores:,sockets:,numnics: -n 'parse-options' -- "$@"`

if [ $? != 0 ] ; then echo "Failed parsing options." >&2 ; exit 1 ; fi

# echo "$OPTS"
eval set -- "$OPTS"

VERBOSE=false
HELP=false
NODELIST=""
SETSIZE=0
SECONDS=30
VFLAG=""
IFLAG=""
MULTINIC=0
PPN=""
PPN_DEFAULT=8
MULTINIC=false
NICMAPPING=""
DISPLAYDATA=""
DEBUG=""
MPI="none"
MPIFLAG=""
MEM=131072
REPS="auto"
BFLAG=""
BCASTDIR=/tmp/dgnettest.tmp
CLASS=2
THRESHOLD=0.9
CV_THRESHOLD=0.05
NUMA=true
STATS=""
CFLAG=""
PARTITION=""

NICMIN=0
NICMAX=1
SOCKETS=2
CORES=64

declare -a nicNumaNum

# Shared Receive Queue - Memory footprint reduction is required for all2all
export FI_OFI_RXM_USE_SRX=1

while true; do
  case "$1" in
    -h | --help )       HELP=true; shift ;;
    -b | --bcast )      BFLAG="--bcast=$BCASTDIR";  shift;;
    -c | --class )      CLASS=$2; shift; shift;;
    -C | --concurrent)  MULTINIC=true; shift;;
    -d | --debug)       DEBUG="-d"; shift;;
    -D | --data)        DISPLAYDATA="-D"; shift;;
    -i | --ignore)      IFLAG="-i"; shift;;
    -l | --latency)     CV_THRESHOLD="$2"; shift; shift;;
    -m | --mem  )       MEM=$2; shift; shift;;
    -M | --mpi )        MPI=$2; shift; shift;;
    -n | --nodelist )   NODELIST="$2"; shift; shift;;
    -N | --NIC  )       NIC=$2; shift; shift;;
    -P | --partition )  PARTITION="-p ${2}"; shift; shift;;
    -p | --ppn )        PPN=$2; shift; shift;;
    -r | --reps )       REPS=$2; shift; shift;;
    -R | --counter)     CFLAG="-C $2"; shift; shift;;
    -s | --sets )       SETSIZE="$2"; shift; shift;;
    -S | --stats)       STATS="-S"; shift;;
    -t | --time )       SECONDS="$2"; shift; shift;;
    -T | --threshold)   THRESHOLD=$2; shift; shift;;
    -v )                VERBOSE=true; QFLAG=""; shift;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

if [ $HELP == true ] ; then
   print_help $0
   exit 1
fi

if [ "$NODELIST" == "" ] ; then
  NODELIST=`sinfo -rh | grep idle | awk '{print $6}' | cut -d$'\n' -f1`
fi

if [ $VERBOSE == true ] || [ "${DEBUG}" == "-d" ]; then
  echo NODELIST=$NODELIST
  echo SETSIZE=$SETSIZE
fi 

#generate_nodelist_sets $NODELIST

if [ $VERBOSE == true ]; then
  VFLAG="-v"
  export MPICH_VERSION_DISPLAY=1
  export MPICH_OFI_VERBOSE=1
  export MPICH_OFI_NIC_VERBOSE=1
fi

if [ $MPI != "none" ]; then
  MPIFLAG="--mpi ${MPI}"
fi

if (( $(echo "$THRESHOLD < 0" |bc -l) )) || (( $(echo "1 < $THRESHOLD" |bc -l) )); then
  echo "Threshold needs to be between 0 and 1"
  print_help $0
  exit 1
fi

if (( $(echo "$CV_THRESHOLD < 0" |bc -l) )) || (( $(echo "1 < $CV_THRESHOLD" |bc -l) )); then
  echo "Latency threshold needs to be between 0 and 1"
  print_help $0
  exit 1
fi

# Configure the switch/latency test set sizes to match the class type
case "$CLASS" in
  0 ) SWITCH_SIZE=64;;
  1 ) SWITCH_SIZE=32;;
  2 ) SWITCH_SIZE=16;;
  3 ) SWITCH_SIZE=16;;
  4 ) SWITCH_SIZE=16;;
  * ) echo "Invalid Class type entered. Please select 0-4..."; print_help $0;;
esac

# Temporary workaround for a problem with XRC om MOFED5.2
which ofed_info &> /dev/null
if [ $? -eq 0 ] ; then
   ofed_info -s | grep -e '5.2' > /dev/null
   if [ $? -eq 0 ] ; then
      echo "Disabling XRC in `ofed_info -s`"
      export FI_VERBS_PREFER_XRC=0
   fi
fi

# Check if the user selected a NIC
if [ ! -z $NIC ] && [ "$MULTINIC" == false ]; then
   if [ $NIC -lt $NICMIN ] || [ $NIC -gt $NICMAX ] ; then
      echo "Selected NIC isn't valid. Please select either ${NICMIN} or ${NICMAX}."
      print_help $0
      exit 1
   fi
else
   NIC="-1"
fi

nodesets=`generate_nodelist_sets $NODELIST "${PARTITION}"`
for set in ${nodesets[@]}; do
   cores=`echo "${set}" | tr '_' ' ' | cut -d' ' -f2`
   sockets=`echo "${set}" | tr '_' ' ' | cut -d' ' -f3`
   NICMAX=`echo "${set}" | tr '_' ' ' | cut -d' ' -f4`
   NICMAX=$(( NICMAX - 1 )) #value should be the max NIC # that's valid.
   numNuma=`echo "${set}" | tr '_' ' ' | cut -d' ' -f5`
   nodesetlist=`echo "${set}" | tr '_' ' ' | cut -d' ' -f6`

   #Check if this is a multi-nic system using NUMA. If it is a multi-NIC system and NUMA is present, 
   #  gather system information to properly place tests on proper CPU cores.
   if [ "${numNuma}" == "-1" ]; then
      #failed to use NUMA to gather data, run in "default" mode
      if [ $VERBOSE == true ] || [ "${DEBUG}" == "-d" ]; then
         echo "Failed to find NUMA files, setting NIC to 0"
      fi
 
      export MPICH_OFI_NUM_NICS=1
      NICMAPPING="-N 0"
      MULTINIC=false
      NUMA=false
      PPN=$PPN_DEFAULT
   fi
 
   if [ "$PPN" == "" ]; then
      PPN=$numNuma
   fi

   # Generate a CPU list for use with tests.
   for i in $(seq 0 1 ${sockets}); do
      if [ $PPN -gt $cores ]; then
         tmp=$(seq -s, $((cores * i)) 1 $((cores * i + cores - 1)) | sed -E "s/ /,/g")
      else
         tmp=$(seq -s, $((cores * i)) $((cores / PPN)) $((cores * i + cores - 1)) | sed -E "s/ /,/g")
      fi
      eval "socket${i}Cpus"="$tmp"
   done

   #Set up the run's NIC information. Due to how intertwined NUMA is to multi-NIC, support for 
   #  NUMA must be available for this to auto-setup the code.
   if [ ${NUMA} == true ]; then
      #Set MPI node division to be a known
      if [ "$MULTINIC" == true ]; then
         export MPICH_OFI_NUM_NICS=$(( NICMAX + 1 ))
         if [ "$PPN" == "${numNuma}" ]; then 
            NICMAPPING=""
            for i in $(seq ${NICMIN} 1 ${NICMAX}); do
               list=""
               for j in $(seq ${i} $(( NICMAX + 1 )) ${numNuma}); do
                  list+=",$j"
               done
               NICMAPPING+=";${i}:${list:1}"
            done
            NICMAPPING=${NICMAPPING:1} 

            #For a concurrent run, zipper the supported NICs together. This should match with the NIC mapping provided to the test
            #  set in the environment variables. Currently, each NIC is on its own socket.
            cpumap=""
            for nic in $(seq ${NICMIN} 1 ${NICMAX}) ; do 
               eval mapfile -t "nic${nic}Array" < <( seq -s, $((cores * nic)) $((cores / PPN)) $((cores * nic + cores - 1)) | sed -E "s/,/ /g" )
            done
 
            val=( ${nic0Array} )
            for (( i=0; i < ${#val[@]}; ++i)); do
               for j in $(seq ${NICMIN} 1 ${NICMAX}); do
                  tmp="nic${j}Array"
                  val=( ${!tmp} )
                  cpumap+=",${val[$i]}"
               done
            done
            cpumap=${cpumap:1}
         else
            #handle data if PPN != #NUMA Nodes
            # need to tell which ranks to use which NICs in order to help dgnettest run correctly
            if [ "${NIC}" == "-1" ] ; then
               echo "Currently, if you select a -p that isn't ${numNuma}, you will also need to provide an MPICH_OFI_NIC_MAPPING mapping of \"NICs:Ranks\" to -N. Exiting..."
               exit 1
            fi

            NICMAPPING=${NIC}              
         fi
      elif [ ${NIC} -ne -1 ]; then
         export MPICH_OFI_NUM_NICS="1:$NIC"
         NICMAPPING="-N $NIC"
      fi
   fi

   # ToDo: installation path to nettest executable
   NETTEST=dgnettest
   #copy dgnettest out to the tmp directory and run from there. This avoids errors when running with --bcast
   if [ "$BFLAG" != "" ]; then
      cp $NETTEST /tmp/$NETTEST
      cd /tmp
      NETTEST="/tmp/$NETTEST"
   fi

   ALCLINE="salloc ${PARTITION} --nodelist=${nodesetlist::-2} --ntasks-per-node=$PPN --exclusive -Q sh -c"
   SRUNLINE="srun $MPIFLAG $BFLAG"
   CMDLINE="$NETTEST -p $PPN -r $REPS -m $MEM -t $SECONDS -c $CLASS -T $THRESHOLD -l $CV_THRESHOLD $IFLAG $VFLAG $CFLAG $DEBUG"

   if [ $SETSIZE == 0 ]; then
      #Concurrent NIC Run
      if [ "$MULTINIC" == true ]; then
        if [ $VERBOSE == true ]; then
           echo "running in concurrent mode"
        fi
        #check PCIe before running
        check_fw_version ${NICMIN} ${NICMAX} ${nodesetlist::-2} "${PARTITION}"
        #print out concurrent run info, include full allocation line + cpu_binding to help with future debug
        if [ $VERBOSE == true ] || [ "${DEBUG}" == "-d" ]; then
           echo "Using Command Line:"
           CPUBIND="--cpu_bind=map_cpu:${cpumap}"
           echo "$ALCLINE \"${SRUNLINE} ${CPUBIND} ${CMDLINE} ${DISPLAYDATA} ${NICMAPPING}\""
           echo ""
        fi

        #Loopback test shouldn't be run in Concurrent mode
        for nic in $(seq ${NICMIN} 1 ${NICMAX}) ; do
           soc=$(( NIC % sockets ))
           tmp="socket${soc}Cpus"
           CPUBIND="--cpu_bind=map_cpu:${!tmp}"
           echo "Running loopback tests on NIC ${nic} over : $NODELIST"
           $ALCLINE "MPICH_NO_LOCAL=1 MPICH_OFI_NUM_NICS=\"1:${nic}\" ${SRUNLINE} ${CPUBIND} ${CMDLINE} -N ${nic} -s 65536 ${STATS} loopback"
           echo ""
        done

        #Set up env for all other tests to use all NICs together
        export MPICH_OFI_NUM_NICS=$(( NICMAX + 1 ))
        export MPICH_OFI_NIC_POLICY="USER"
        export MPICH_OFI_NIC_MAPPING="${NICMAPPING}"
        NICMAPPING="-N \"${NICMAPPING}\""

        #Set CPU_BIND for the srun to use the cpumap for concurrent runs. This MUST be set together with 
        # allocating the node, otherwise the CPU binding will not work as expected
        CPUBIND="--cpu_bind=map_cpu:${cpumap}"

        echo "Running switch tests over : $NODELIST"
        $ALCLINE "${SRUNLINE} ${CPUBIND} ${CMDLINE} ${NICMAPPING} -s ${SWITCH_SIZE} -S all2all bisect"
        echo ""
        echo "Running group tests over : $NODELIST"
        $ALCLINE "${SRUNLINE} ${CPUBIND} ${CMDLINE} ${NICMAPPING} -s 512 -S all2all bisect"
        echo ""

     #Single NIC Run
     elif [ ${NIC} -ne -1 ]; then
        if [ $VERBOSE == true ]; then
           echo "running in single NIC mode over nic${NIC}"
        fi
        #check PCIe before running
        check_fw_version ${NIC} ${NIC} ${nodesetlist::-2} "${PARTITION}"

        soc=$(( NIC % sockets ))
        tmp="socket${soc}Cpus"
        CPUBIND="--cpu_bind=map_cpu:${!tmp}"
        #print out single NIC run info, include full allocation line + cpu_binding to help with future debug
        if [ $VERBOSE == true ] || [ "${DEBUG}" == "-d" ]; then
           echo "Using Command Line:"
           echo "$ALCLINE \"${SRUNLINE} ${CPUBIND} ${CMDLINE} ${DISPLAYDATA} ${NICMAPPING}\""
           echo ""
        fi

        echo "Running loopback tests over : $NODELIST"
        $ALCLINE "MPICH_NO_LOCAL=1 ${SRUNLINE} ${CPUBIND} ${CMDLINE} ${NICMAPPING} -s 65536 ${STATS} loopback"
        echo ""
        echo "Running switch tests over : $NODELIST"
        $ALCLINE "${SRUNLINE} ${CMDLINE} ${NICMAPPING} -s ${SWITCH_SIZE} -S all2all bisect"
        echo ""
        echo "Running group tests over : $NODELIST"
        $ALCLINE "${SRUNLINE} ${CMDLINE} ${NICMAPPING} -s 512 -S all2all bisect"
        echo ""

     #Default Single NIC Run over all NICs
     else
        if [ $VERBOSE == true ]; then
           echo "running in single NIC mode over nics ${NICMIN}-${NICMAX}"
        fi
        #check PCIe before running
        check_fw_version ${NICMIN} ${NICMAX} ${nodesetlist::-2} "${PARTITION}"

        #print out all single NIC run info, include full allocation line + cpu_binding to help with future debug
        if [ $VERBOSE == true ] || [ "${DEBUG}" == "-d" ]; then
           echo "Using Command Lines:"
           for nic in $(seq ${NICMIN} 1 ${NICMAX}) ; do
              soc=$(( nic % sockets ))
              tmp="socket${soc}Cpus"
              CPUBIND="--cpu_bind=map_cpu:${!tmp}"
              echo "$ALCLINE \"MPICH_OFI_NUM_NICS=\"1:${nic}\" ${SRUNLINE} ${CPUBIND} ${CMDLINE} ${DISPLAYDATA} -N ${nic}\""
           done
           echo ""
        fi

        for nic in $(seq ${NICMIN} 1 ${NICMAX}) ; do
           soc=$(( nic % sockets ))
           tmp="socket${soc}Cpus"
           CPUBIND="--cpu_bind=map_cpu:${!tmp}"
           echo "Running loopback tests on NIC ${nic} over : $NODELIST"
           $ALCLINE "MPICH_NO_LOCAL=1 MPICH_OFI_NUM_NICS=\"1:${nic}\" ${SRUNLINE} ${CPUBIND} ${CMDLINE} -N ${nic} -s 65536 ${STATS} loopback"
           echo ""
        done
	
        for nic in $(seq ${NICMIN} 1 ${NICMAX}) ; do
           soc=$(( nic % sockets ))
           tmp="socket${soc}Cpus"
           CPUBIND="--cpu_bind=map_cpu:${!tmp}"
           echo "Running switch tests on NIC ${nic} over : $NODELIST"
           $ALCLINE "MPICH_OFI_NUM_NICS=\"1:${nic}\" ${SRUNLINE} ${CPUBIND} ${CMDLINE} -N ${nic} -s ${SWITCH_SIZE} -S all2all bisect"
           echo ""
        done

        for nic in $(seq ${NICMIN} 1 ${NICMAX}) ; do
           soc=$(( nic % sockets ))
           tmp="socket${soc}Cpus"
           CPUBIND="--cpu_bind=map_cpu:${!tmp}"
           echo "Running group tests on NIC ${nic} over : $NODELIST"
           $ALCLINE "MPICH_OFI_NUM_NICS=\"1:${nic}\" ${SRUNLINE} ${CPUBIND} ${CMDLINE} -N ${nic} -s 512 -S all2all bisect"
           echo ""
        done
     fi

   #Run with user selected options
   else
      if [ $VERBOSE == true ]; then
         echo "running in user custom mode"
      fi
      #check PCIe before running
      check_fw_version ${NIC} ${NIC} ${nodesetlist::-2} "${PARTITION}"

      if [ "$MULTINIC" == true ]; then
         export MPICH_OFI_NIC_POLICY="USER"
         export MPICH_OFI_NIC_MAPPING="${NICMAPPING}"
         NICMAPPING="-N \"${NICMAPPING}\""
         CPUBIND="--cpu_bind=map_cpu:${cpumap}"
      else
         if [ "$NIC" == "-1" ]; then
            NIC=0
         fi
         export MPICH_OFI_NUM_NICS=1:$NIC
         NICMAPPING="-N $NIC"
         soc=$(( NIC % sockets ))
         tmp="socket${soc}Cpus"
         CPUBIND="--cpu_bind=map_cpu:${!tmp}"
      fi

      if [ $VERBOSE == true ] || [ "${DEBUG}" == "-d" ]; then
         echo "Using Command Line:"
         echo "$ALCLINE \"${SRUNLINE} ${CPUBIND} ${CMDLINE} ${DISPLAYDATA} ${NICMAPPING} -s ${SETSIZE} ${STATS} $*\""
         echo ""
      fi

      echo "Running tests over : $NODELIST"
      $ALCLINE "${SRUNLINE} ${CPUBIND} ${CMDLINE} ${DISPLAYDATA} ${NICMAPPING} -s ${SETSIZE} ${STATS} $*"
      echo""
   fi
done

#clean up file from tmp
if [ "$BFLAG" == "" ] && [ -f "/tmp/dgnettest" ]; then
   rm -f /tmp/dgnettest
fi
