#!/bin/bash
################################################################################
# Copyright 2021 Hewlett Packard Enterprise Development LP
################################################################################
# bwcheck.sh:  Multi-node IB bandwidth check
# version 1.2  Oct 21 2021
VERSION="1.2"

# Turn off this warning ...  Conflicting CPU frequency values detected
IBWRFLAGS="-F"

# Control of pdsh
PDSHFLAGS="-f 256"
port=18523
xfersize=65536
seconds=30
verbose=false
runpdsh=true
program=`basename $0`
cmd=/usr/local/diag/bin/$program
args=""
hostname=`hostname`
logfile=/tmp/$program.log.$$
server_logfile=/tmp/$program.server.log.$$
errlog=/tmp/$program.errlog.$$
hostname_check=false
usedev=""
devselect=""

# check for PCIe errors if the bandwidth is less than threshold
threshold=11000

usage() {
   if [ $runpdsh == true ] ; then
     args="nodelist"
   else
     args="server"
   fi
   echo "Usage: $0 [-hvV][-d device][-t secs] $args"
}

help() {
   usage
   echo "    -d device   select a specific device (default all)"
   echo "    -t seconds  specify runtime for each test (default $seconds)"
   echo "    -V          Version"
   echo "    -v          verbose"
   echo ""
   echo "Node lists follow pdsh format, for example: "
   echo ""
   echo "    $program x1000c0s[0-7]b[0-1]n[0-1]"
   echo ""
   echo "Please limit the tests to one cabinet at a time"
   echo ""
}

vmsg()
{
  if [ $runpdsh == true ] ; then prefix="$program:"; fi
  if [ ! -z "$SLURM_JOBID" ] ; then prefix="`hostname`:"; fi
  if [ $verbose == true ] ; then
    echo $prefix $1
  fi
}

msg()
{
  if [ $runpdsh == true ] ; then
     echo "$program: $@"
  else
     echo "$hostname: $@"
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
     if [ ${#tokens[@]} -eq 3 ] ; then
       bw=$( printf "%.0f" ${tokens[2]} )
       sum=$((sum + bw))
       if [ $bw -le $min ] ; then min=$bw; fi
       if [ $bw -ge $max ] ; then max=$bw; fi
       bandwidths+=($bw)
       hosts+=(${tokens[0]})
       devices+=(${tokens[1]})
       ((count++))
     elif [ "${tokens[3]}" == "skipped" ] ; then
       ((skipped++))
     elif [ "${tokens[3]}" == "failed" ] ; then
       ((failed++))
     fi
  done < $logfile

  # expecting one or two devices per node
  if [ $count -gt $nhosts ] ; then
    ndevices=$((2 * nhosts))
  else
    ndevices=$nhosts
  fi
  missing=$((ndevices - count))

  printf "Hosts = %d Count = %d Skipped = %d Failed = %d Missing = %d\n" $nhosts $count $skipped $failed $missing
  if [ $count -gt 0 ] ; then
    mean=$((sum/count));
    printf "Min = %d Mean = %d Max = %d\n" $min $mean $max
  fi

  # report nodes whose performance is less than 99% of the mean
  tolerance=$((mean/100 ))
  min_bw=$((mean-5*tolerance))
  id=0
  for bw in ${bandwidths[@]}
  do
    if [ $bw -lt $min_bw ] ; then
       percent=$((100*bw / min_bw))
       echo "${hosts[id]} ${devices[id]} bandwidth is low $bw" MB/s "($percent%)"
       ((failed++))
    fi
    ((id++))
  done

  if [ $missing -gt 0 ] ; then
       echo "Test results missing (logfile is $logfile)"
  elif [ $hostname_check == false ] ; then
       echo "Test failed to start on some nodes (see $logfile)"
  elif [ $count -gt 0 ] && [ $failed -eq 0 ] ; then
       echo "Test passed"
  else
       echo "Test failed (logfile is $logfile)"
  fi
}

# check for being run inside SLURM
if [ -z "$SLURM_JOBID" ] ; then
  prepend=""
else
  runpdsh=false
  prepend="`hostname`: "
fi

while true; do
  case "$1" in
    -d | --device )   usedev="$2"; shift; shift;;
    -h | --help )     help; exit 1;;
    -p | --pdsh )     runpdsh=false; shift;;
    -t | --time )     seconds="$2"; shift; shift;;
    -v )              verbose=true; args="$args -v"; shift;;
    -V )              echo"Version: $VERSION"; shift;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

# we can get the nodelist from the environment when run under SLURM
# otherwise it needs to come from the command line

if [ ! -z "$SLURM_JOB_NODELIST" ] ; then
   nodelist=$SLURM_JOB_NODELIST
else

   if [ $# -eq 0 ] ; then
     usage
     exit 1
   fi
   nodelist=$1

   # run test locally if nodelist matches the hostname
   if [ $nodelist == $hostname ] ; then
      vmsg "running local test"
      runpdsh=false
      prepend="`hostname`: "
   fi
fi

if [ "$usedev" != "" ] ; then
   devselect="-d $usedev"
fi

# driver script runs pdsh
if [ $runpdsh == true ] ; then

   if [ ! -x "$(command -v pdsh)" ] ; then
       msg "pdsh is not installed, try running $program with srun"
       exit 1
   fi

   # Set pdsh timeout
   pdsh_timeout=$((seconds * 2 + 60))
   vmsg "timeout set to $pdsh_timeout"

   # use pdsh to convert nodelist to a list of hostnames
   msg "checking nodelist"
   hosts=(`pdsh $PDSHFLAGS -u 60 -w $nodelist -N hostname 2>$logfile | sort`)
   nhosts=${#hosts[@]}
   if [ -s $logfile ] ; then
     msg "errors in nodelist (see $logfile) $nhosts remain"
     checklog $logfile
     hostname_check=false
   else
     hostname_check=true
     vmsg "$nhosts nodes in nodelist"
   fi
   if [ $nhosts -eq 0 ] ; then
     msg "nodelist is empty"
     exit 1
   fi

   # construct a new nodelist from those that responded
   checked=`echo "${hosts[*]}" | sed 's/ /,/g'`

   # check the firmware versions
   versions=`(pdsh $PDSHFLAGS -u $pdsh_timeout -w $checked ibv_devinfo | grep fw_ver | awk '{print $3}' | sort | uniq | tr '\n' ' ')`
   msg "firmware version: $versions"

   # run the test
   cmdline="pdsh $PDSHFLAGS -u $pdsh_timeout -w $checked $cmd -p $args $devselect -t $seconds ${hosts[@]}"

   if [ $verbose == true ] ; then
     msg "starting $seconds second test on $checked"
     echo $cmdline
   fi
   msg "starting test"
   $cmdline | tee -a $logfile
   report

else

# script has been started by pdsh

ibtest() {

   # PCIe errors befor test
   pcie_errors_before=`dmesg | grep "PCIe error" | wc -l`

   port=$1
   ib_write_bw $IBWRFLAGS -p $port -d $device -s $xfersize > $server_logfile &
   sleep 5
   ib_write_bw $IBWRFLAGS $server -p $port -d $device -D $seconds -s $xfersize> $logfile
   status=$?
   if [ $status -eq 0 ] ; then
      bw=`grep $xfersize $logfile | awk '{print $4}' | cut -f1 -d'.'`
      if [ $bw -gt $threshold ]  ; then
         echo $bw
      else
         pcie_errors=`dmesg | grep "PCIe error" | wc -l`
         echo "$bw PCIe errors $((pcie_errors - pcie_errors_before)) $pcie_errors"
      fi
   else
      cat $logfile >> $errlog
      echo "test failed (logfile is $hostname:$errlog)"
   fi
   wait
}

ibcheck() {
    state=`ibv_devinfo -d $device | grep state | awk '{print $2}'`
    if [ "$state" == "PORT_ACTIVE" ] ; then
        return 0
    else
        # echo "$device: test failed $state" >&2
        return 1
    fi
}

ipcheck()
{
   INTERFACE="hsn$1"
   HOSTNAME="`hostname`-$INTERFACE"

   LINK_STATUS=`ip addr show $INTERFACE | grep -e "NO-CARRIER" -e "DOWN"`
   if [ $? -eq 0 ] ; then
      echo "${prepend}test failed for $INTERFACE link is down"
      return 1
   fi

   # configured IP address stripping off the subnet mask
   IP_CONFIGURED=`ip addr show $INTERFACE | grep inet | grep -v inet6 | awk '{print $2}' | cut -f1 -d'/'`
   if [ -z "$IP_CONFIGURED" ] ; then
      echo "${prepend}test failed IP address is not configured for $INTERFACE"
      return 1
   fi
   IP_NAMESERVER=`getent hosts $HOSTNAME | awk '{print $1}'`
   if [ -z "$IP_NAMESERVER" ] ; then
      echo "${prepend}IP lookup for $HOSTNAME failed"
      return 1
   fi
   if [ "$IP_CONFIGURED" != "$IP_NAMESERVER" ] ; then
      echo "${prepend}IP address check failed for $INTERFACE: Configured: $IP_CONFIGURED Lookup: $IP_NAMESERVER"
      return 1
   fi
   return 0
}

devices=`ibv_devices | grep mlx5 | awk '{print $1}'`
server=$hostname
client=$hostname

# make sure that there are no lurking copies of the test
pkill ib_write_bw

for device in $devices
do
     device_id=`echo $device | cut -f2 -d'_'`
     if [ -z "$usedev" ] || [ "$usedev" == "$device" ] ; then
       # some systems don't have ibstat
       if [ -x "$(command -v ibstat)" ] ; then
          type=`ibstat -d $device | grep "CA type" | awk '{print $3}'`
          rate=`ibstat -d $device | grep "Rate" | awk '{print $2}'`
          vmsg "device $device type $type rate $rate port $port server $server client $client"
       fi
       ipcheck $device_id
       if [ $? -eq 0 ] ; then
          ibcheck $device
          if [ $? -eq 0 ] ; then
            output=`ibtest $port $server $client`
            echo "${prepend}$device: $output"
          else
            echo "${prepend}$device: test failed ($state)"
          fi
       fi
   fi
done


# all done on test node

fi

exit 0
