njobs ?= 10

runpt2pt:
	for nn in 2 4 8 16 32 64 128 256 512 1024; do \
	  for ppn in 1 8 16 32 64 120 128 128; do \
	    ss="$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=200G" && echo $${ss} && qsub -l select=$${ss} round_robin.pbs ; \
	  done ; \
	done

runalltoall:
	for nn in 2 4 8 16 32 64 128 256 512 1024; do \
	  for ppn in 16 32 64 120 128 128; do \
	    ss="$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=200G" && echo $${ss} && qsub -l select=$${ss} alltoall.pbs ; \
	  done ; \
	done

runmany: stress-ng/stress-ng
	for j in $$(seq 1 $(njobs)); do \
	  echo -n "submitting job #$$j: " ; \
	  qsub ./stressng_test.pbs ; if [ $$(($$j%10)) -eq 0 ]; then sleep 1s; fi ; \
	done

stress-ng/stress-ng:
	git submodule update --init --recursive
	git clean -xdf stress-ng
	make CC=/usr/bin/gcc -C stress-ng -j 24

eigen/INSTALL:
	git submodule add -b 3.4 https://gitlab.com/libeigen/eigen

dense_matmul: dense_matmul.C eigen/INSTALL
	mpicxx -o $@ $< -O3 -I$$(pwd)/eigen -fopenmp

netgauge/$(NCAR_BUILD_ENV):
	top_dir=$$(pwd) ; \
	mkdir -p $${top_dir}/netgauge && cd $${top_dir}/netgauge ; \
	[ -d netgauge-2.4.6 ] || curl -sL https://htor.inf.ethz.ch/research/netgauge/netgauge-2.4.6.tar.gz | tar xz ; \
	cd $${top_dir}/netgauge/netgauge-2.4.6 ; \
	$${top_dir}/netgauge/netgauge-2.4.6/configure HRT_ARCH=6 --prefix=$${top_dir}/$@ ; \
	make && make install

clean:
	rm -f log-* *~ *.pbs.o* nr*.log

clobber:
	$(MAKE) clean
	git clean -xdf --exclude "*/"

qdelall:
	qdel $$(qstat -u $${USER} 2>/dev/null | grep ".desched" | egrep "round|alltoall|stressng" | cut -d'.' -f1)


results-pt2pt:
	for file in pt2pt-nr*.log; do \
	  stub=$$(echo $${file} | cut -d'.' -f1) ; \
	  [ -f $${file} ] && echo $${file} || continue ; \
	  grep "# --> END execution" $${file} >/dev/null 2>&1 || continue ; \
	  awk '/# --> BEGIN execution/{flag=1;next}/# --> END execution/{flag=0}flag' $${file} > $${file}.csv ; \
	  cp $${file}.csv results-$${stub}.latest.csv ; \
	done
	grep "Slowest" pt2pt-nr*.log

results-alltoall:
	for file in alltoall-nr*.log; do \
	  stub=$$(echo $${file} | cut -d'.' -f1) ; \
	  [ -f $${file} ] && echo $${file} || continue ; \
	  grep "# --> END execution" $${file} >/dev/null 2>&1 || continue ; \
	  awk '/# --> BEGIN execution/{flag=1;next}/# --> END execution/{flag=0}flag' $${file} > $${file}.txt ; \
	  cp $${file}.txt results-$${stub}.latest.txt ; \
	done
	grep "MPICH Slingshot Network Summary" alltoall-nr*.log
	grep "avg_time" alltoall-nr*.log
	grep "Slowest" alltoall-nr*.log
