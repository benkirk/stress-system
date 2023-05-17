#!/bin/bash 
# Copyright 2021-2022 Hewlett Packard Enterprise Development LP
version="1.4"

program=`basename $0`
program_path=$0
tmpfile=/tmp/cxiberstat.tmp
errfile=/tmp/cxiberstat.err
max_n_len=4
declare -A c_bins
declare -A u_bins
fullest_c_bin=0
fullest_u_bin=0
fullest_nonmin_c_bin=0
fullest_nonmin_u_bin=0
dev_w=6
ber_w=9
hist_w=50
min_val=""

d_flag=""
stat_d_flag=""
u_flag=""
stat_p_flag=""
u_val="4"
P_flag=""
partition=""
use_pdsh=false
sort_by_err_asc=false
sort_by_err_desc=false
nodelist=""
pdsh_fanout="-f 256"
include_histograms=true
all=true
ccwthreshold=6
ucwthreshold=0

help() {
    echo    "Tool for measuring and displaying Slingshot NIC link bit error rates for"
    echo    "many nodes in a system"
    echo    ""
    echo    "Usage: $program [-dhpsV] [NODELIST]"
    echo    "    -d DEVICE    select a specific device (default all)"
    echo -e "    -e EXP       Only used with \"-f\" option. Limit output to nodes with"
    echo    "                 a corrected BER above the given rate. Output is combined"
    echo -e "                 with \"-E\" output when both are specified (default is ${ccwthreshold})"
    echo -e "                 (Ex: \"-e 5\" corresponds to \"Corrected BERs above 1e-05\")"
    echo -e "    -E EXP       Only used with \"-f\" option. Limit output to nodes with"
    echo    "                 an uncorrected BER above the given rate. Output is combined"
    echo -e "                 with \"-e\" output when both are specified (default is ${ucwthreshold})"
    echo -e "                 (Ex: \"-E 8\" corresponds to \"Uncorrected BERS above 1e-08\")"
    echo    "    -f           display only nodes with errors"
    echo    "    -h           display this help and exit"
    echo    "    -p           use pdsh rather than Slurm (requires -w option)"
    echo    "    -P           the Slurm partition to use (default is Slurm default)"
    echo    "    -s           sort by UCW, CCW descending (default Node, Device ascending)"
    echo    "    -S           sort by UCW, CCW ascending (default Node, Device ascending)"
    echo    "    -u           rate measurement duration in seconds (default 4)"
    echo    "    -V           output version information and exit"
    echo    ""
    echo    "Node lists follow pdsh format, for example:"
    echo    ""
    echo    "    $program x1000c0s[0-7]b[0-1]n[0-1]"
    echo    ""
    echo    "Can be run locally by supplying the hostname for NODELIST"
}

calc_min_val() {
    min_val=`echo "(1 / $u_val) / 212500000000" | bc -l | xargs printf "%.4g\n"`
    printf "Note: Using a duration of %s seconds means the minimum measurable rate is %.4g\n" "$u_val" $min_val
}

build_cmd() {
    cmd="cxi_stat -r ${stat_p_flag} ${stat_d_flag}"
    # Pick lines we care about
    cmd="${cmd} | grep -E '(Device:|BER:)'"
    # Get just device and BER values
    cmd="${cmd} | grep -oE '[^[:space:]]+$'"
    cmd="${cmd} | sed -e 's/0.000e+00/0/g'"
    # Put each device's values on a single line
    cmd="${cmd} | tr '\n' ' ' | sed -E -e 's/(cxi[0-9]+)/\n\1/g'"
    # Remove leading newline & add trailing newline
    cmd="${cmd} | sed -e '/^$/d' && printf '\n'"
}

get_idle_nodelist() {
    if [[ -z $partition ]]; then
        partition=`sinfo -rh | grep -E '^[^\*]+\* ' | awk '{print $1}' | cut -d$'\n' -f1`
        if [[ -z $partition ]]; then
            echo "No default Slurm partition found. Please specify one with -P."
            exit 1
        fi
    fi
    nodelist=`sinfo -rh | grep idle | grep "$partition" | awk '{print $6}' | cut -d$'\n' -f1`
    if [[ -z $nodelist ]]; then
        echo "No idle nodes found for partition $partition"
        exit 1
    fi
}

print_node_ber_data() {
    build_cmd
    eval $cmd | sed -e "s/^/$(hostname): /"
}

# $1: bin value
# $2: flag saying we care about this value when deciding to print histogram
check_fullest_c_bin() {
    if [[ $1 -gt $fullest_c_bin ]]; then
        fullest_c_bin=$1
        if [[ $2 == true ]]; then
            fullest_nonmin_c_bin=$1
        fi
    fi
}

# $1: bin value
# $2: flag saying we care about this value when deciding to print histogram
check_fullest_u_bin() {
    if [[ $1 -gt $fullest_u_bin ]]; then
        fullest_u_bin=$1
        if [[ $2 == true ]]; then
            fullest_nonmin_u_bin=$1
        fi
    fi
}

sort_results() {
    # Sort the file, taking into account values below the min
    sed -i "s/<${min_val}/0/g" $tmpfile

    if [[ $sort_by_err_desc == true ]]; then
        LC_ALL=C sort -gr -k4 -k3 -o $tmpfile $tmpfile
    elif [[ $sort_by_err_asc == true ]]; then
        LC_ALL=C sort -g -k4 -k3 -o $tmpfile $tmpfile
    else
        sort -k1 -k2 -o $tmpfile $tmpfile
    fi

    if [[ $all == false ]]; then
        ccw=0
        ucw=0
        if [[ $ccwthreshold -ne 0 ]]; then
            ccw=`echo "1*10^(-${ccwthreshold})" | bc -l`
        fi

        if [[ $ucwthreshold -ne 0 ]]; then
            ucw=`echo "1*10^(-${ucwthreshold})" | bc -l`
        fi
        awk -i inplace -v ccwthresh=$ccw -v ucwthresh=$ucw '($3 + 0) > ccwthresh || ($4 + 0) > ucwthresh {print $0}' $tmpfile
    fi

    sed -i "s/ 0/ <min/g" $tmpfile

    for i in {5..17}; do
        c_bins[$i]=0
        u_bins[$i]=0
    done
    while IFS=' ' read -ra words; do
        n_len=${#words[0]}
        if [[ ${words[2]} == "<"* ]]; then
            c_bin="<"
        else
            c_bin=${words[2]#*-}
        fi
        if [[ ${words[3]} == "<"* ]]; then
            u_bin="<"
        else
            u_bin=${words[3]#*-}
        fi

        # Determine Node column width
        if [[ $n_len -gt $max_n_len ]]; then
            max_n_len=$n_len
        fi

        # Sort BERs into bins
        case $c_bin in
            05) ((c_bins[5]++))
               check_fullest_c_bin ${c_bins[5]} true
               ;;
            06) ((c_bins[6]++))
               check_fullest_c_bin ${c_bins[6]} true
               ;;
            07) ((c_bins[7]++))
               check_fullest_c_bin ${c_bins[7]} true
               ;;
            08) ((c_bins[8]++))
               check_fullest_c_bin ${c_bins[8]} true
               ;;
            09) ((c_bins[9]++))
               check_fullest_c_bin ${c_bins[9]} true
               ;;
            10) ((c_bins[10]++))
                check_fullest_c_bin ${c_bins[10]} true
                ;;
            11) ((c_bins[11]++))
                check_fullest_c_bin ${c_bins[11]} true
                ;;
            12) ((c_bins[12]++))
                check_fullest_c_bin ${c_bins[12]} true
                ;;
            13) ((c_bins[13]++))
                check_fullest_c_bin ${c_bins[13]} true
                ;;
            14) ((c_bins[14]++))
                check_fullest_c_bin ${c_bins[14]} true
                ;;
            15) ((c_bins[15]++))
                check_fullest_c_bin ${c_bins[15]} true
                ;;
            16) ((c_bins[16]++))
                check_fullest_c_bin ${c_bins[16]} true
                ;;
            "<") ((c_bins[17]++))
                check_fullest_c_bin ${c_bins[17]} false
                ;;
        esac
        case $u_bin in
            05) ((u_bins[5]++))
               check_fullest_u_bin ${u_bins[5]} true
               ;;
            06) ((u_bins[6]++))
               check_fullest_u_bin ${u_bins[6]} true
               ;;
            07) ((u_bins[7]++))
               check_fullest_u_bin ${u_bins[7]} true
               ;;
            08) ((u_bins[8]++))
               check_fullest_u_bin ${u_bins[8]} true
               ;;
            09) ((u_bins[9]++))
               check_fullest_u_bin ${u_bins[9]} true
               ;;
            10) ((u_bins[10]++))
                check_fullest_u_bin ${u_bins[10]} true
                ;;
            11) ((u_bins[11]++))
                check_fullest_u_bin ${u_bins[11]} true
                ;;
            12) ((u_bins[12]++))
                check_fullest_u_bin ${u_bins[12]} true
                ;;
            13) ((u_bins[13]++))
                check_fullest_u_bin ${u_bins[13]} true
                ;;
            14) ((u_bins[14]++))
                check_fullest_u_bin ${u_bins[14]} true
                ;;
            15) ((u_bins[15]++))
                check_fullest_u_bin ${u_bins[15]} true
                ;;
            16) ((u_bins[16]++))
                check_fullest_u_bin ${u_bins[16]} true
                ;;
            "<") ((u_bins[17]++))
                check_fullest_u_bin ${c_bins[17]} false
                ;;
        esac
    done < $tmpfile
}

print_table() {
    printf "%${max_n_len}s  %${dev_w}s  " "Node" "Device"
    printf "%${ber_w}s  %${ber_w}s\n" "CCW_BER" "UCW_BER"
    while IFS=' ' read -ra words; do
        printf "%${max_n_len}s  %${dev_w}s  " "${words[0]}" "${words[1]}"
        printf "%${ber_w}s  %${ber_w}s\n" "${words[2]}" "${words[3]}"
    done < $tmpfile
}

# $1: bin value
# $2: fullest bin value
# $3: max bar length
print_bar() {
    bar_len=`echo "(($1 * $3) + $2 - 1) / $2" | bc -l`
    bar_len=${bar_len%.*}
    if [[ $bar_len -gt 0 ]]; then
        printf "=%.0s" `seq 1 $bar_len`
    fi
}

print_histograms() {
    echo -e "\nCCW BER Summary"
    if [[ $fullest_nonmin_c_bin -gt 0 ]]; then
        count_w=${#fullest_c_bin}
        max_len=$(( hist_w - 8 - count_w ))
        printf "  Bin  %${count_w}s Histogram\n" "#"

        # Regular bins
        for i in `seq 5 ${min_val#*-}`; do
            printf "1e-%02d: %${count_w}s " "$i" "${c_bins[$i]}"
            if [[ ${c_bins[$i]} -ne 0 ]]; then
                print_bar ${c_bins[$i]} $fullest_c_bin $max_len
            fi
            printf "\n"
        done

        # Below minimum value
        printf " <min: %${count_w}s " "${c_bins[17]}"
        if [[ ${c_bins[17]} -ne 0 ]]; then
            print_bar ${c_bins[17]} $fullest_c_bin $max_len
        fi
        printf "\n"
    else
        echo "No CCW BERs above min measurable value"
    fi

    echo -e "\nUCW BER Summary"
    if [[ $fullest_nonmin_u_bin -gt 0 ]]; then
        count_w=${#fullest_u_bin}
        max_len=$(( hist_w - 8 - count_w ))
        printf "  Bin  %${count_w}s Histogram\n" "#"

        # Regular bins
        for i in `seq 5 ${min_val#*-}`; do
            printf "1e-%02d: %${count_w}s " "$i" "${u_bins[$i]}"
            if [[ ${u_bins[$i]} -ne 0 ]]; then
                print_bar ${u_bins[$i]} $fullest_u_bin $max_len
            fi
            printf "\n"
        done

        # Below minimum value
        printf " <min: %${count_w}s " "${u_bins[17]}"
        if [[ ${u_bins[17]} -ne 0 ]]; then
            print_bar ${u_bins[17]} $fullest_u_bin $max_len
        fi
        printf "\n"
    else
        echo "No UCW BERs above min measurable value"
    fi
}

### Execution starts here ###

while true; do
    case "$1" in
        -d) stat_d_flag="-d cxi$2"
            d_flag="-d $2"
            shift
            shift
            ;;
        -e) let ccwthreshold=$2
            shift
            shift
            ;;
        -E) let ucwthreshold=$2
            shift
            shift
            ;;
        -f) all=false
            shift
            ;;
        -h) help
            exit 0
            ;;
        -p) use_pdsh=true
            shift
            ;;
        -P) P_flag="-p $2"
            partition="$2"
            shift
            shift
            ;;
        -s) sort_by_err_desc=true
            shift
            ;;
        -S) sort_by_err_asc=true
            shift
            ;;
        -u) u_flag="-u $2"
            stat_p_flag="-p $2"
            u_val="$2"
            shift
            shift
            ;;
        -V) echo "$program: $version"
            exit 0
            ;;
        *)  break
            ;;
    esac
done

nodelist=$1

numregex='^[0-9]+$'
if [[ ! ($ccwthreshold =~ $numregex) || $ccwthreshold -gt 12 || $ccwthreshold -lt 0 ]]; then
    echo "Please enter a valid number between 0 and 12 for the correctable BER output limit"
    help
    exit 0
fi

if [[ ! ($ucwthreshold =~ $numregex) || $ucwthreshold -gt 12 || $ucwthreshold -lt 0 ]]; then
    echo "Please enter a valid number between 0 and 12 for the uncorrectable BER output limit"
    help
    exit 0
fi

# The following scenarios are valid:
# - Executed on a node by a user
# - Executed on a node by Slurm
# - Running as driver script, using Slurm with all idle nodes
# - Running as driver script, using Slurm with provided nodelist
# - Running as driver script, using pdsh with provided nodelist
if [[ $nodelist == `hostname` ]]; then
    print_node_ber_data 1>$tmpfile 2>$errfile
    include_histograms=false
elif [[ $use_pdsh == true ]]; then
    if [[ -z $nodelist ]]; then
        echo "Please specify a list of nodes to run on"
        exit 1
    else
        build_cmd
        pdsh $pdsh_fanout -w "$nodelist" "$cmd" 1>$tmpfile 2>$errfile
    fi
elif [[ -z $nodelist && ! -z $SLURMD_NODENAME ]]; then
    nodelist=$SLURMD_NODENAME
    print_node_ber_data
    exit 0
else
    if [[ -z $nodelist ]]; then
        get_idle_nodelist
    fi
    # Copy script to tmp and run from there to avoid --bcast errors
    cp $program_path /tmp/$program
    cd /tmp
    # This could use the command directly like pdsh, but broadcasting a
    # tmp copy of the script will result in slurm showing the job as
    # "cxiberstat.sh" rather than just "bash"
    srun $P_flag -o $tmpfile -e $errfile -w $nodelist --bcast=/tmp/$program /tmp/$program $d_flag $u_flag
    rm /tmp/$program
fi

if [[ -f $tmpfile ]]; then
    # Some pdsh error cases result in empty lines. Remove them
    sed -i '/^[^[:space:]]*:[[:space:]]$/d' $tmpfile
    if [[ -s $tmpfile ]]; then
        calc_min_val
        sort_results
        print_table
        if [[ $include_histograms == true ]]; then
            print_histograms
        fi
    fi
    rm $tmpfile
fi

if [[ -f $errfile ]]; then
    if [[ -s $errfile ]]; then
        echo "Errors occurred:"
        cat $errfile
    fi
    rm $errfile
fi
