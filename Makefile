njobs ?= 10

runmany: stress-ng/stress-ng
	for j in $$(seq 1 $(njobs)); do \
	  echo -n "submitting job #$$j: " ; \
	  qsub ./stressng_test.pbs ; if [ $$(($$j%10)) -eq 0 ]; then sleep 1s; fi ; \
	done

stress-ng/stress-ng:
	git submodule update --init --recursive
	git clean -xdf stress-ng
	make CC=/usr/bin/gcc -C stress-ng -j 24

clean:
	rm -f log-* *~ *.pbs.o*

qdelall:
	qdel $$(qstat -u $${USER} 2>/dev/null | grep ".desched" | grep "stressng" | cut -d'.' -f1)
