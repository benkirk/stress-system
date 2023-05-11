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

netgauge/$(NCAR_BUILD_ENV):
	top_dir=$$(pwd) ; \
	mkdir -p $${top_dir}/netgauge && cd $${top_dir}/netgauge ; \
	[ -d netgauge-2.4.6 ] || curl -sL https://htor.inf.ethz.ch/research/netgauge/netgauge-2.4.6.tar.gz | tar xz ; \
	cd $${top_dir}/netgauge/netgauge-2.4.6 ; \
	$${top_dir}/netgauge/netgauge-2.4.6/configure HRT_ARCH=6 --prefix=$${top_dir}/$@ ; \
	make && make install

clean:
	rm -f log-* *~ *.pbs.o*

qdelall:
	qdel $$(qstat -u $${USER} 2>/dev/null | grep ".desched" | grep "stressng" | cut -d'.' -f1)
