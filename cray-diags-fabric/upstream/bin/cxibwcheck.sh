#!/bin/bash 
################################################################################
# Copyright 2021-2022 Hewlett Packard Enterprise Development LP
################################################################################
# bwcheck.sh:  Multi-node CXI bandwidth check
# version 1.5  March 2 2022
VERSION="1.5"
NUMREGEX='^[0-9]+$'
AMAMAC="02:00:00"

CBWRFLAGS=""

# Control of pdsh
PDSHFLAGS="-f 256"
PORT=18523 #initial default port to try using for test
portnum=-1
xfersize=65536
seconds=30
verbose=0
runpdsh=true
program=`basename $0`
local_cmd=$0
cmd=/usr/local/diag/bin/$program
path=/usr/bin
bin=$path/cxi_write_bw
cxistat=$path/cxi_stat
args="" 
hostname=`hostname`
fileheader=/tmp/$program
logfile=$fileheader.log.$$
server_logfile=$fileheader.server.log.$$
errlog=$fileheader.errlog.$$
server_errlog=$fileheader.server.errlog.$$
tmpfile=$fileheader.tmp
hostname_check=false
usedev=""
devselect=""
servercore=1
clientcore=2
cores=`lscpu | grep "Core(s)" | cut -d ':' -f2 | sed -E "s/ //g"`
sockets=`lscpu | grep "Socket(s)" | cut -d ':' -f2 | sed -E "s/ //g"`
cores=$((cores * sockets))
broadcast=false
pflag=""
no_gpus=""

MAX_PCIE_SPEED="16 GT/s"
MAX_PCIE_ESM_SPEED="25 GT/s"
MAX_PCIE_WIDTH="16"

# check for PCIe errors if the bandwidth is less than threshold
pcie_err_threshold=11000

min_pass_bw=36000

usage() {
   if [ $runpdsh == true ] ; then
     args="nodelist"
   else
     args="server"
   fi
   echo "Usage: $0 [-hbDisvV][-c server:client][-d device][-p port][-t secs] $args"
}

delete_logs() {
   file=${1:none}

   if [ "${file}" == "none" ] || [ "$file" == "" ]; then
      lfile="$fileheader.log.*"
      server_lfile="$fileheader.server.log.*"
      elfile="$fileheader.errlog.*"
      server_elfile="$fileheader.server.errlog.*"

      rm ${lfile}
      rm ${server_lfile}
      rm ${elfile}
      rm ${server_elfile}
   else
      if [ -f $file ]; then
         rm $file
      else
         echo "Log file failed to delete, file doesn't exist..."
         if [ $verbose -ge 2 ]; then 
            echo "File is $file"
         fi
      fi
   fi
}

help() {
   usage
   echo "    -b                          Broadcast out a copy of the script to all nodes"
   echo "                                selected for the test."
   echo "    -c server_core:client_core  Specify the core offsets (relative to nearest"
   echo                                  "NUMA node) to use for the server and client"
   echo                                  "runs of cxi_write_bw."
   echo "                                Default is $servercore:$clientcore."
   echo "    -C                          Check the PCIe status of each node."
   echo "                                **NOTE - must have root permissions to run this check."
   echo "    -d device                   Select a specific device (default all)."
   echo "    -D                          Deletes all the log files out in /tmp and exits."
   echo "    -g                          Disable the use of GPU memory."
   echo "    -i                          Ignore port checking. Runs with default port if" 
   echo "                                none entered (default $PORT)."
   echo "    -p port                     Select a specific port to run on. (Default auto)."
   echo "    -s                          Save log files after successful run."
   echo "    -t seconds                  Specify runtime for each test (default $seconds)."
   echo "    -V                          Version"
   echo "    -v                          Verbose (up to 4 times)"
   echo ""
   echo "Node lists follow pdsh format, for example: "
   echo ""
   echo "    $program x1000c0s[0-7]b[0-1]n[0-1]"
   echo ""
   echo "Please limit the tests to one cabinet at a time"
   echo ""
}

checkport()
{
  tmp=`which lsof 2> /dev/null`
  if [ "$?" != 0 ]; then
    #since lsof isn't installed, try using default port
    echo "0"
  else
    re=`lsof -i:$1 -P -n`
    # $? returns 1 if there is no results, 0 if there is results
    if [ "$?" != "1" ] || [ `echo "${re}" | grep -c "^"`  -gt 1 ]; then
      echo "1"
    else
      echo "0"
    fi
  fi
}

getport()
{
  port=$PORT
  # use the limit to set how long we try to check different ports
  eval limit=5
  re=$(checkport $port)
  while [ "$re" != "0" ] && [ $limit -gt 0 ]; do
    # Set the port number to a random number between 1024 and 50174 (less than 65535 max)
    port=$((1024 + $RANDOM % 49151))
    searchstring="IP for"

    re=$(checkport $port) 
    let limit+=-1
  done

  if [ "$re" == "0" ]; then
    echo "${port}"
  else
    echo "-1"
  fi 
}

pciecheck()
{
  #Check that PCI-e is Gen 4 x 16
  INTERFACE="hsn$1"
  let re=0   

  # Check PCI Speed and Width
  speed=`cat /sys/class/net/${INTERFACE}/device/current_link_speed 2>> $errlog`
  width=`cat /sys/class/net/${INTERFACE}/device/current_link_width 2>> $errlog`
  ESM=`$cxistat | grep "FW Version" | awk '{print $3}' | sort | uniq | grep ESM 2>> $errlog`

  if [ ! -z "$ESM" ]; then
     esm_speed=`cat /sys/class/net/${INTERFACE}/device/properties/current_esm_link_speed 2>> $errlog`
     if [ $? != 0 ] || [ "${esm_speed}" != "${MAX_PCIE_ESM_SPEED}" ]; then
        msg "found ESM mode support"
        msg "found PCIe Speed at ${speed}"
        let re=1
     fi
  else
     if [ "${speed}" != "${MAX_PCIE_SPEED}" ]; then
        msg "found PCIe Speed at ${speed}"
        let re=1
     fi
  fi

  if [ "${width}" != "${MAX_PCIE_WIDTH}" ]; then
     msg "found PCI width at ${width}"
     let re=1
  fi

  return ${re}
}

vmsg() 
{ 
  verblvl=${2:-1}
  writeout="false"
  if [ $verbose -ge $verblvl ] ; then
     writeout="true"
  fi
  
  msg "${1}" $writeout
}

msg()
{
  writeout=${2:-true}

  if [ $runpdsh == true ] ; then prefix="$program:"; fi
  if [ ! -z "$SLURM_JOBID" ] ; then prefix="`hostname`:"; fi

  if [ "${writeout}" == "true" ]; then
     echo $prefix "${1}" >> >(tee -a $logfile)
  else
     echo $prefix "${1}" >> $logfile
  fi
}

checklog() 
{
  log=$1
  checkstr="Could not resolve hostname"
  missing=`grep "$checkstr" $log | awk '{print $6}' | sed -e 's/://'`
  if [ ! -z "$missing" ] ; then
     msg "$checkstr:" `echo $missing | sed -e 's/ /,/g'`
  fi
}

report()
{
  min=50000
  max=0
  failed=0
  skipped=0
  count=0
  missing=0
  bandwidths=()
  hosts=()
  devices=()

  while read line
  do
     tokens=($line)
     if [ ${#tokens[@]} -eq 3 ] && [ "${tokens[0]}" != "cxibwcheck.sh:" ]; then
       bw=$( printf "%.0f" ${tokens[2]} 2> /dev/null )
       if [ $? -eq 0 ]; then
          sum=$((sum + bw))
          if [ $bw -le $min ] ; then min=$bw; fi
          if [ $bw -ge $max ] ; then max=$bw; fi
          bandwidths+=($bw)
          hosts+=(${tokens[0]})
          devices+=(${tokens[1]})
          ((count++))
       fi
     #Dont know of a skipped condition that can show up with this test currently
     # Leaving this section in here incase there is additional states to check
     # for
     #elif [ "${tokens[3]}" == "skipped" ] ; then
     #  ((skipped++))
     elif [ "${tokens[3]}" == "failed" ] ; then
       ((failed++))
     fi
  done < $logfile

  # expecting one or many devices per node
  if [ $count -gt $nhosts ] ; then
    devcnt=`grep -e cxi[0-9]: $logfile | cut -d':' -f2 | sort -u | wc -l`
    ndevices=$((devcnt * nhosts))
  else
    ndevices=$nhosts
  fi
  missing=$((ndevices - count))

  printf "Hosts = %d Count = %d Skipped = %d Failed = %d Missing = %d\n" $nhosts $count $skipped $failed $missing
  if [ $count -gt 0 ] ; then
    mean=$((sum/count));
    printf "Min = %d Mean = %d Max = %d\n" $min $mean $max
  fi

  # report nodes whose performance is less than 95% of the mean
  tolerance=$((mean/100 ))
  min_bw=$((mean-5*tolerance))
  id=0
  for bw in ${bandwidths[@]}
  do
    if [ $bw -lt $min_bw ] ; then
       percent=$((100*bw / mean))
       echo "${hosts[id]} ${devices[id]} bandwidth is low $bw" MB/s "($percent%)"
       ((failed++))
    elif [ $bw -lt $min_pass_bw ]; then
       echo "${hosts[id]} ${devices[id]} bandwidth is low $bw" MB/s "(<$min_pass_bw)"
       ((failed++))
    fi
    ((id++))
  done

  if [ $missing -gt 0 ] ; then
       msg "Test results missing (logfile is $logfile)"
  elif [ $hostname_check == false ] ; then
       msg "Test failed to start on some nodes (see $logfile)"
  elif [ $count -gt 0 ] && [ $failed -eq 0 ] ; then
       msg "Test passed"
  else
       msg "Test failed (logfile is $logfile)"
  fi
}

# check for being run inside SLURM
if [ -z "$SLURM_JOBID" ] ; then
  prepend=""
else
  runpdsh=false
  prepend="`hostname`: "
fi

ignore=0
iflag=""
sflag=""
pcicheck=false
delete=false

while true; do
  case "$1" in
    -b | --broadcast) broadcast=true; shift;;
    -c | --cores)     servercore=( `echo $2 | cut -d':' -f 1` )
                      clientcore=( `echo $2 | cut -d':' -f 2` )
                      shift; shift;;
    -C | --pci )      pcicheck=true; shift;;
    -d | --device )   usedev="$2"; shift; shift;;
    -D | --delete )   delete=true; shift;;
    -g | --no-gpus )  no_gpus=1; shift;;
    -h | --help )     help; exit 1;;
    -i | --ignore)    ignore=1; iflag="-i"; shift;;
    -P | --pdsh )     runpdsh=false; shift;;
    -p | --port )     portnum=$2; shift; shift;;
    -s | --save )     sflag="-s"; shift;;
    -t | --time )     seconds="$2"; shift; shift;;
    -v )              verbose=$( expr $verbose + 1 ); args="$args -v"; shift;;
    -V )              echo "Version: $VERSION"; exit 1;;
    -- ) shift; break ;;
    * )	break ;;
  esac
done

# we can get the nodelist from the environment when run under SLURM
# otherwise it needs to come from the command line

if [ ! -z "$SLURM_JOB_NODELIST" ] ; then
   nodelist=$SLURM_JOB_NODELIST
else

   if [ $# -eq 0 ] ; then
     echo "Couldn't find a list of nodes to run on. Exiting..."
     usage
     exit 1
   fi
   nodelist=$@

   # run test locally if nodelist matches the hostname
   if [ $nodelist == $hostname ] && [ "$runpdsh" == "true" ] ; then
      vmsg "running local test"
      runpdsh=false
   fi
fi

if [ "$portnum" != "-1" ]; then
   pflag="-p $portnum"
fi

if [ "$usedev" != "" ] ; then
   devselect="-d $usedev"
fi

if ! [[ $servercore =~ $NUMREGEX ]] || [ $servercore -lt 0 ] || [ $servercore -gt $cores ]; then
   tmp=$(( cores - 1 ))
   msg "Invalid value for server core, please select a value between 0 and $tmp"
   usage
   exit 1
fi

if ! [[ $clientcore =~ $NUMREGEX ]] || [ $clientcore -lt 0 ] || [ $clientcore -gt $cores ]; then
   tmp=$(( cores - 1 ))
   msg "Invalid value for client core, please select a value between 0 and $tmp"
   usage
   exit 1
fi

# driver script runs pdsh
if [ $runpdsh == true ] ; then 
   pciflag=""

   if [ ! -x "$(command -v pdsh)" ] ; then
       msg "pdsh is not installed, try running $program with srun"
       exit 1
   fi

   #check if we're just trying to delete logs
   if [ "$delete" == "true" ]; then
      #copy out files, if requested. 
      if [[ "$broadcast" == "true" ]]; then
         newcmd=/tmp/$program
         pdcp -w $checked $local_cmd $newcmd
         cmd=$newcmd
      fi

       pdsh $PDSHFLAGS -u 60 -w "$nodelist" "${cmd} -D"
       exit 1
   fi

   #get # of devices
   OLDIFS=$IFS   # Save current IFS
   IFS=$'\n'      # Change IFS to new line
   tmp=`(pdsh $PDSHFLAGS -u 60 -w "$nodelist" "${cxistat} -l" 2>> >(tee -a $errlog) | sort | uniq | sed s/[a-z0-9]*://g)`
   if [ "$?" != "0" ]; then
      msg "Failed to get number of devices (see $errlog), exiting..."
      exit 1
   fi
   devices=( {$tmp} )
   IFS=$OLDIFS
   devcnt=${#devices[@]}

   # Set pdsh timeout 
   pdsh_timeout=$((seconds * 2 * devcnt + 65))
   vmsg "timeout set to $pdsh_timeout" 2

   # use pdsh to convert nodelist to a list of hostnames
   vmsg "checking nodelist" 2
   hosts=(`pdsh $PDSHFLAGS -u 60 -w "$nodelist" -N hostname 2>$logfile | sort`)

   nhosts=${#hosts[@]}
   if [ -s $logfile ] ; then 
     msg "errors in nodelist (see $logfile) $nhosts remain"
     checklog $logfile
     hostname_check=false
   else 
     hostname_check=true
     vmsg "$nhosts nodes in nodelist" 2
   fi

   if [ $nhosts -eq 0 ] ; then
     msg "nodelist is empty"
     exit 1
   fi

   # construct a new nodelist from those that responded
   checked=`echo "${hosts[*]}" | sed 's/ /,/g'`

   #verify the nhosts list works; sometimes the hostnames don't work out to the nodes if run from a UAN or SMS type node
   `pdsh $PDSHFLAGS -u 60 -w $checked "echo hello" &> /dev/null`
   if [ $? -ne 0 ]; then
      vmsg "failed to use the checked hostname list, attempting run using provided node list." 2
      checked="${nodelist}"
   fi

   # check the firmware versions
   versions=`(pdsh $PDSHFLAGS -u $pdsh_timeout -w $checked $cxistat 2>> $errlog | grep "FW Version" | awk '{print $4}' | sort | uniq | tr '\n' ' ')`
   msg "firmware version: $versions"

   #copy out files, if requested
   if [[ "$broadcast" == "true" ]]; then
      newcmd=/tmp/$program
      pdcp -w $checked $local_cmd $newcmd
      cmd=$newcmd
   fi

   if [[ "$pcicheck" == "true" ]]; then
      pciflag="-C"
   fi

   # run the test
   cmdline="pdsh $PDSHFLAGS -u $pdsh_timeout -w $checked $cmd -P $args $devselect -t $seconds -c $servercore:$clientcore $sflag $pflag $iflag $pciflag ${hosts[@]}"
 
   vmsg "starting $seconds second test on $checked using core offsets $servercore:$clientcore" 2
   vmsg "$cmdline" 2  
   vmsg "starting test" 2
   if [ $verbose -ge 4 ]; then
      $cmdline >> >(tee -a $logfile) 2>> $errlog | dshbak
   elif [ $verbose -ge 1 ]; then
      $cmdline >> >(tee -a $logfile) 2>> $errlog
   else
      $cmdline > $tmpfile 2>> $errlog
      cat $tmpfile >> $logfile

      #The only way to get BW readings is from this file. Remove BW readings and report only errors
      while read line
      do
         tokens=($line)
         if [ ${#tokens[@]} -eq 3 ]; then
           bw=$( printf "%.0f" ${tokens[2]} 2> /dev/null )
           if [ $? -ne 0 ]; then
              echo $line
           fi
         fi
      done < $tmpfile
      delete_logs $tmpfile
   fi

   if [ "$?" == "0" ]; then
      report
      if [ "$sflag" != "-s" ] && [ "$(cat $errlog | hexdump -C)" == "" ];then
         delete_logs $errlog
         delete_logs $logfile
      fi
   else
      msg "Errors were deteced when trying to start the PDSH run (see $errlog). Exiting..."
      exit 1
   fi

else 

# script has been started by pdsh

cxitest() {
   server=$1
   device=$2 
   client=$3 
   portnum=$4
   gpu_map=$5

   # Pick client & server cores based on nearest NUMA node and offset
   devicenum=$(echo $device | tr -dc '0-9')
   numa=`cat /sys/class/cxi/${device}/device/numa_node 2>> $errlog`
   if [ "$?" != "0" ]; then 
      msg "failed to get numa information, skipping $device test"
      return
   fi
   if [[ "$numa" == "-1" ]]; then
       # BP node with known issue retrieving NUMA node
       case $devicenum in
           0) numa=3;;
           1) numa=1;;
           2) numa=0;;
           3) numa=2;;
       esac
   fi
   cpulist=`cat /sys/devices/system/node/node${numa}/cpulist 2>> $errlog`
   if [ "$?" != "0" ]; then
      msg "failed to get CPU information, skipping $device test"
      return
   fi
   cpulist=${cpulist%,*}  # no threads
   first=${cpulist%-*}
   s_core_val=$(((first + servercore) % cores))
   c_core_val=$(((first + clientcore) % cores))

   # Determine which GPU's memory to use, if any
   gpu_flags=""
   if [[ "$gpu_map" == "GP" ]]; then
       gpu_flags="--gpu-type NVIDIA"
       case $devicenum in
           0) gpu_flags+=" --tx-gpu 3";;
           1) gpu_flags+=" --tx-gpu 2";;
           2) gpu_flags+=" --tx-gpu 1";;
           3) gpu_flags+=" --tx-gpu 0";;
       esac
   elif [[ "$gpu_map" == "BP" ]]; then
       gpu_flags="--gpu-type AMD"
       case $devicenum in
           0) gpu_flags+=" --tx-gpu 0 --rx-gpu 1";;
           1) gpu_flags+=" --tx-gpu 2 --rx-gpu 3";;
           2) gpu_flags+=" --tx-gpu 4 --rx-gpu 5";;
           3) gpu_flags+=" --tx-gpu 6 --rx-gpu 7";;
       esac
   fi

   # PCIe errors before test
   echo "*------------------------- cxi $devicenum -------------------------*" >> $server_errlog
   echo "*------------------------- cxi $devicenum -------------------------*" >> $errlog
   pcie_errors_before=`dmesg | grep "PCIe error" | wc -l`

   taskset -c $s_core_val $bin --port $portnum --device $device $gpu_flags> $server_logfile 2>> $server_errlog &
   sleep 4
   taskset -c $c_core_val $bin $server --port $portnum --device $device $gpu_flags -D $seconds -s $xfersize -b> $logfile 2>> $errlog
   status=$?

   #Check if run via slurm, if so, try without CPU bind for run
   if [ $status -ne 0 ] && [ ! -z "$SLURM_JOBID" ]; then
         $bin --port $portnum --device $device $gpu_flags> $server_logfile 2>> $server_errlog &
         sleep 4
         $bin $server --port $portnum --device $device $gpu_flags -D $seconds -s $xfersize -b> $logfile 2>> $errlog
         status=$?
   fi 

   if [ $status -eq 0 ] ; then 
      bw=`grep $xfersize $logfile | grep -v "Size" | awk '{print $3}'`
      bw=${bw%.*}
      if [ $bw -ge $min_pass_bw ]; then
         # check if this is a slurm job and if so, if the verbosity is at least 1 to display good BW results
         if [ -z "$SLURM_JOBID" ] || [ $verbose -ge 1 ]  ; then
            echo $bw
         fi
      elif [ $bw -gt $pcie_err_threshold ]; then
         # If running through slurm or standalone, check against minimum BW
         if [ ! -z "$SLURM_JOBID" ] || [ "$nodelist" == "$hostname" ]; then
            echo "$bw - bandwidth is low (<$min_pass_bw)" >> >(tee -a $errlog)
         # If being driven by pdsh, the driver script will do the min BW check
         elif [ -z "$SLURM_JOBID" ] || [ $verbose -ge 1 ]  ; then
            echo $bw
         fi
      else
         pcie_errors=`dmesg | grep "PCIe error" | wc -l`
	 echo "$bw PCIe errors $((pcie_errors - pcie_errors_before)) $pcie_errors"  >> >(tee -a $errlog)
      fi
   else
      cat $logfile >> $errlog
      msg "test failed (logfile is $hostname:$errlog)"
      pkill cxi_write_bw
   fi
   echo "*------------------------------------------------------------------*" >> $server_errlog
   echo "*------------------------------------------------------------------*" >> $errlog
   wait
   #echo "end of test section"
}

cxicheck() {
    state=`$cxistat --device $device | grep state | awk '{print $3}' 2>> $errlog`
    if [ "$?" != "1" ] && [ "$state" == "up" ] ; then
        return 0
    else
        return 1
    fi
}

ipcheck()
{
   INTERFACE="hsn$1"
   HOSTNAME="`hostname`-$INTERFACE"

   LINK_STATUS=`ip addr show $INTERFACE | grep -e "NO-CARRIER" -e "DOWN"`
   if [ $? -eq 0 ] ; then
      msg "test failed for $INTERFACE link is down"
      return 1
   fi

   # configured IP address stripping off the subnet mask
   IP_CONFIGURED=`ip addr show $INTERFACE 2>> $errlog | grep inet | grep -v inet6 | awk '{print $2}' | cut -f1 -d'/'`
   if [ -z "$IP_CONFIGURED" ] ; then
      msg "test failed IP address is not configured for $INTERFACE"
      return 1
   fi
   IP_NAMESERVER=`getent hosts $HOSTNAME 2>> $errlog | awk '{print $1}'`
   if [ -z "$IP_NAMESERVER" ] ; then
      vmsg "IP lookup for $HOSTNAME failed, trying $(hostname)" 2

      HOSTNAME="`hostname`"
      IP_NAMESERVER=`getent hosts $HOSTNAME 2>> $errlog | awk '{print $1}'`
      if [ -z "$IP_NAMESERVER" ] ; then
         msg "IP lookup for $HOSTNAME failed"
         return 1
      fi
   fi
   if [ "$IP_CONFIGURED" != "$IP_NAMESERVER" ] ; then
      msg "IP address check failed for $INTERFACE: Configured: $IP_CONFIGURED Lookup: $IP_NAMESERVER"
      return 1
   fi
   return 0
}

amacheck()
{
   INTERFACE="hsn$1"
   BAD=`ip a 2>> $errlog |grep -A1 ${INTERFACE}|grep ether | grep -v $AMAMAC`
   if [ ! -z "$BAD" ]; then
      msg "Bad $INTERFACE AMA found:  ${BAD}"
      return 1
   fi
   return 0
}

cleanup_logs()
{
   #check that the error log file is empty
   server_output=`cat $server_errlog | grep -v "*-------------------------"`
   output=`cat $errlog | grep -v "*-------------------------"`

   if [ -z "$server_output" ] && [ -z "$output" ]; then
      delete_logs $server_errlog
      delete_logs $errlog
      delete_logs $server_logfile
      delete_logs $logfile 
   fi
   return 0
}

   if [ "$delete" == "true" ]; then
      delete_logs
      exit 0
   fi   

   server=$hostname
   client=$hostname

   if [ "$portnum" == "-1" ] && [ "$ignore" == 0 ]; then
     portnum=$(getport)
     if [ "$portnum" == "-1" ]; then
       msg "Failed to find an unused port to test on, exiting..."
       exit 1
     fi
   elif [ "$ignore" == 0 ]; then
      if (( $portnum -lt 1 )) || (( $portnum -gt 65535 )); then
         msg "Port number provided is invalid. Please enter a number from 1 to 65535"
         usage
         exit 1
      fi
   else
      portnum=$PORT
   fi

   #get # of devices
   OLDIFS=$IFS    # Save current IFS
   IFS=$'\n'      # Change IFS to new line
   tmp=`$cxistat -l`
   devices=($tmp)
   IFS=$OLDIFS

   # Check for GPUs
   gpu_map="NA"
   if [ -z "$no_gpus" ]; then
       bp=`lspci -nn | grep "1002:7408" | wc -l`
       gp=`lspci -nn | grep "10de:20b2" | wc -l`
       if [ $bp -gt 0 ]; then
           export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/rocm/lib
           gpu_map="BP"
       elif [ $gp -gt 0 ]; then
           gpu_map="GP"
       fi
   fi

   # make sure that there are no lurking copies of the test
   pkill -2 cxi_write_bw
   sleep 5
   pkill cxi_write_bw

   for device in ${devices[@]}; do
      device_id=`echo $device | cut -f2 -d'i'`
      if [ -z "$usedev" ] || [ "$usedev" == "$device" ] ; then
         type=`$cxistat --device $device | grep "Link type" | awk '{print $3}'`
         rate=`$cxistat --device $device | grep "Link speed" | awk '{print $3}'`
         vmsg "device $device type $type rate $rate port $port server $server client $client gpu_map $gpu_map" 2

         cxicheck $device
         if [ $? -eq 1 ]; then
            msg "$device: test failed (link status: $state)"
            vmsg "check the logs($logfile) and error logs($errlog) for more details"
            continue
         fi

         ipcheck $device_id
         if [ $? -eq 1 ] ; then
            vmsg "Please validate the configured IP addresses. The test will continue but errors may be due to address configuration issues." 2
         fi

         amacheck $device_id
         if [ $? -eq 1 ]; then
            msg "$device: test failed (link status: $state)"
            vmsg "check the logs($logfile) and error logs($errlog) for more details"
            continue;
         fi
         
         if [[ "$pcicheck" == "true" ]]; then
            pciecheck $device_id $cxistat
            if [ $? -eq 1 ]; then
               msg "$device: test failed (link status: $state)"
               vmsg "check the logs($logfile) and error logs($errlog) for more details"
               continue;
            fi
         fi

         output=`cxitest $server $device $client $portnum $gpu_map`
         if [ $? -eq 0 ] ; then
            if [[ "$pcicheck" == "true" ]]; then
               pciecheck $device_id $cxistat
               if [ $? -eq 1 ]; then
                  msg "$device: test failed (link status: $state)"
                  msg "pcie performance degraded after test"
               else
                  if [ ! -z "$output" ]; then
                      msg "$device: $output"
                  fi
                  if [ "$sflag" != "-s" ];then
                     cleanup_logs 
                  fi
               fi
            else
               if [ ! -z "$output" ]; then
                  msg "$device: $output"
               fi
               if [ "$sflag" != "-s" ];then
                  cleanup_logs
               fi
            fi
         else
            msg "$device: test failed (link status: $state)"
            vmsg "check the logs($logfile) and error logs($errlog) for more details"
         fi
      fi
   done
# all done on test node
fi

exit 0

