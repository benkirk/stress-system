njobs ?= 10

runmany: stress-ng/stress-ng
	for j in $$(seq 1 $(njobs)); do \
	  qsub ./stressng_test.pbs ;\
	done

stress-ng/stress-ng:
	git submodule update --init --recursive
	cd stress-ng
	module --force purge 2>&1
	make

clean:
	rm -f log-* *~ *.pbs.o*
