njobs ?= 10
queue ?= R1331670

#	for nn in 2048 1536 1024 512; do \

runstartup:
	for nn in 512 448 256 128 64 32 16 8 4 2; do \
	  for ppn in 128 64 32; do \
	    for try in 0 1 2; do \
	      ss="$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=200G" && echo $${ss} && qsub -q $(queue) -l select=$${ss} startup.pbs ; \
	    done ; \
	  done ; \
	done

runpt2pt:
	for nn in 2 4 8 16 32 64 128 256 512; do \
	  for ppn in 1 8 16 32 64 120 128; do \
	    ss="$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=200G" && echo $${ss} && qsub -q $(queue) -l select=$${ss} round_robin.pbs ; \
	  done ; \
	done

runalltoall:
	for nn in 2 4 8 16 32 64 128 256 512 1024; do \
	  for ppn in 4 8 16 32 64 120 128; do \
	    ss="$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=200G" && echo $${ss} && qsub -q $(queue) -l select=$${ss} alltoall.pbs ; \
	  done ; \
	done

runallreduce:
	for nn in 2 4 8 16 32 64 128 256 512 1024; do \
	  for ppn in 4 8 16 32 64 120 128; do \
	    ss="$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=200G" && echo $${ss} && qsub -q $(queue) -l select=$${ss} allreduce.pbs ; \
	  done ; \
	done

runmany: stress-ng/stress-ng
	for j in $$(seq 1 $(njobs)); do \
	  echo -n "submitting job #$$j: " ; \
	  qsub -q $(queue) ./stressng_test.pbs ; if [ $$(($$j%10)) -eq 0 ]; then sleep 1s; fi ; \
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
	qdel $$(qstat -u $${USER} 2>/dev/null | grep ".desch" | egrep "startup|round|alltoall|allreduce|stressng" | cut -d'.' -f1)


results-pt2pt:
	for file in pt2pt-nr*.log; do \
	  stub=$$(echo $${file} | cut -d'.' -f1) ; \
	  grep "# --> END execution" $${file} >/dev/null 2>&1 || continue ; \
	  awk '/# --> BEGIN execution/{flag=1;next}/# --> END execution/{flag=0}flag' $${file} > $${file}.csv ; \
	  cp $${file}.csv results-$${stub}.latest.csv ; \
	done
	grep "Slowest" pt2pt-nr*.log

results-alltoall:
	for file in alltoall-nr*.log; do \
	  stub=$$(echo $${file} | cut -d'.' -f1) ; \
	  grep "# --> END execution" $${file} >/dev/null 2>&1 || continue ; \
	  awk '/# --> BEGIN execution/{flag=1;next}/# --> END execution/{flag=0}flag' $${file} > $${file}.txt ; \
	  cp $${file}.txt results-$${stub}.latest.txt ; \
	done
	grep "MPICH Slingshot Network Summary" alltoall-nr*.log | grep -v "0 network timeouts" || true
	grep "avg_time" alltoall-nr*.log
	grep "Slowest" alltoall-nr*.log

results-allreduce:
	for file in allreduce-nr*.log; do \
	  stub=$$(echo $${file} | cut -d'.' -f1) ; \
	  grep "# --> END execution" $${file} >/dev/null 2>&1 || continue ; \
	  awk '/# --> BEGIN execution/{flag=1;next}/# --> END execution/{flag=0}flag' $${file} > $${file}.txt ; \
	  cp $${file}.txt results-$${stub}.latest.txt ; \
	done
	grep "MPICH Slingshot Network Summary" allreduce-nr*.log | grep -v "0 network timeouts" || true
	grep "avg_time" allreduce-nr*.log
	grep "Slowest" allreduce-nr*.log

results-failures:
	pwd
	egrep "launch failed|RPC timeout|LAUNCH FAILURE" *.pbs.o* | grep -v "+ echo" | sort | uniq  # | cut -d ':' -f2

archive_results:
	timestamp=$$(date +%F@%H:%M) ; \
	mkdir -p logs/$${timestamp} ; \
	mv *.log* *.pbs.o* logs/$${timestamp}
