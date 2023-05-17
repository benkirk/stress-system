run:
	$(MAKE) run_switches
	$(MAKE) run_switchpairs
	$(MAKE) run_switchgroups
	$(MAKE) run_switchgrouppairs


run_switchgroups: switchgroups.txt nodelist.txt
	while read line; do \
	  sg=$$(echo $${line} | cut -d' ' -f1) ; \
	  nn_sg=$$(echo $${line} | cut -d' ' -f3) ; \
          ppn_sg=0 ; \
	  cat nodelist.txt | grep $${sg} | grep deg >/dev/null && ppn_sg=64 || ppn_sg=128; \
	  ss="$${nn_sg}:switchgroup=$${sg}:ncpus=$${ppn_sg}:mpiprocs=$${ppn_sg}:mem=200G" && echo $${ss} && qsub -N dgnettest-sg-$${sg} -l select=$${ss} dgnettest.pbs ; \
	done < $<

run_switchgrouppairs: switchgroups.txt nodelist.txt
	while read line1; do \
	  sg1=$$(echo $${line1} | cut -d' ' -f1) ; \
	  nn_sg1=$$(echo $${line1} | cut -d' ' -f3) ; \
          ppn_sg1=0 ; \
	  cat nodelist.txt | grep $${sg1} | grep deg >/dev/null && ppn_sg1=64 || ppn_sg1=128; \
	  while read line2; do \
	    sg2=$$(echo $${line2} | cut -d' ' -f1) ; \
	    if [ "$${sg1}" == "$${sg2}" ]; then continue ; fi ; \
	    nn_sg2=$$(echo $${line2} | cut -d' ' -f3) ; \
            ppn_sg2=0 ; \
	    cat nodelist.txt | grep $${sg2} | grep deg >/dev/null && ppn_sg2=64 || ppn_sg2=128; \
	    ss="$${nn_sg1}:switch=$${sg1}:ncpus=$${ppn_sg1}:mpiprocs=$${ppn_sg1}:mem=200G+$${nn_sg1}:switch=$${sg2}:ncpus=$${ppn_sg2}:mpiprocs=$${ppn_sg2}:mem=200G" && echo -en "$${ss} \t" && qsub -N dgnettest-sgpair-$${sg1}-$${sg2} -l select=$${ss} dgnettest.pbs ; \
	  done < $< ; \
	done < $<


run_switches: switches.txt nodelist.txt
	while read line; do \
	  sw=$$(echo $${line} | cut -d' ' -f1) ; \
	  nn_sw=$$(echo $${line} | cut -d' ' -f3) ; \
          ppn_sw=0 ; \
	  cat nodelist.txt | grep $${sw} | grep deg >/dev/null && ppn_sw=64 || ppn_sw=128; \
	  ss="$${nn_sw}:switch=$${sw}:ncpus=$${ppn_sw}:mpiprocs=$${ppn_sw}:mem=200G" && echo -en "$${ss} \t" && qsub -N dgnettest-sw-$${sw} -l select=$${ss} dgnettest.pbs ; \
	done < $<

run_switchpairs: switches.txt nodelist.txt
	while read line1; do \
	  sw1=$$(echo $${line1} | cut -d' ' -f1) ; \
	  nn_sw1=$$(echo $${line1} | cut -d' ' -f3) ; \
          ppn_sw1=0 ; \
	  cat nodelist.txt | grep $${sw1} | grep deg >/dev/null && ppn_sw1=64 || ppn_sw1=128; \
	  while read line2; do \
	    sw2=$$(echo $${line2} | cut -d' ' -f1) ; \
	    if [ "$${sw1}" == "$${sw2}" ]; then continue ; fi ; \
	    nn_sw2=$$(echo $${line2} | cut -d' ' -f3) ; \
            ppn_sw2=0 ; \
	    cat nodelist.txt | grep $${sw2} | grep deg >/dev/null && ppn_sw2=64 || ppn_sw2=128; \
	    ss="$${nn_sw1}:switch=$${sw1}:ncpus=$${ppn_sw1}:mpiprocs=$${ppn_sw1}:mem=200G+$${nn_sw1}:switch=$${sw2}:ncpus=$${ppn_sw2}:mpiprocs=$${ppn_sw2}:mem=200G" && echo -en "$${ss} \t" && qsub -N dgnettest-swpair-$${sw1}-$${sw2} -l select=$${ss} dgnettest.pbs ; \
	  done < $< ; \
	done < $<

clean:
	rm -f *.log dgnettest*.o*

clobber:
	$(MAKE) clean
	git clean -xdf --exclude "*/"


nodelist.txt: Makefile
	pbsnodes -a -F json | jq -r '.nodes[].resources_available | .host + " " + .switch + " " + .switchgroup' | sort -k2 > $@.tmp
	mv $@.tmp $@

switchgroups.txt: Makefile
	rm -f $@
	pbsnodes -a -F json | jq -r '.nodes[].resources_available | .host + " " + .switchgroup' | sort -k2 > $@.tmp1
	for sg in $$(cat $@.tmp1 | cut -d ' ' -f2 | sort | uniq); do \
	  echo "$${sg} : $$(grep -c $${sg} $@.tmp1)" >> $@.tmp2 ; \
	done
	rm -f $@.tmp1
	mv $@.tmp2 $@

switches.txt: Makefile
	rm -f $@
	pbsnodes -a -F json | jq -r '.nodes[].resources_available | .host + " " + .switch' | sort -k2 > $@.tmp1
	for sw in $$(cat $@.tmp1 | cut -d ' ' -f2 | sort | uniq); do \
	  echo "$${sw} : $$(grep -c $${sw} $@.tmp1)" >> $@.tmp2 ; \
	done
	rm -f $@.tmp1
	mv $@.tmp2 $@

qdelall:
	qdel $$(qstat -u $${USER} 2>/dev/null | grep ".desched" | egrep "dgnettest" | cut -d'.' -f1)


results:
	grep "dgnettest has " dgnettest-*.log

results-switchgroups:
	grep "dgnettest has " dgnettest-sg-*.log
results-switches:
	grep "dgnettest has " dgnettest-sw-*.log
results-switchgrouppairs:
	grep "dgnettest has " dgnettest-sgpair-*.log
results-switchpairs:
	grep "dgnettest has " dgnettest-swpair-*.log
