


run: switchgroups.txt nodelist.txt
	while read line; do \
	  sg=$$(echo $${line} | cut -d' ' -f1) ; \
	  nn_sg=$$(echo $${line} | cut -d' ' -f3) ; \
          ppn_sg=0 ; \
	  cat nodelist.txt | grep $${sg} | grep deg >/dev/null && ppn_sg=64 || ppn_sg=128; \
	  echo "$${line} \"$${sg}\" \"$${nn_sg}\"" ; \
	  ss="$${nn_sg}:switchgroup=$${sg}:ncpus=$${ppn_sg}:mpiprocs=$${ppn_sg}:mem=200G" && echo $${ss} && qsub -N dgnettest-$${sg} -l select=$${ss} dgnettest.pbs ; \
	done < $<

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

qdelall:
	qdel $$(qstat -u $${USER} 2>/dev/null | grep ".desched" | egrep "dgnettest" | cut -d'.' -f1)
