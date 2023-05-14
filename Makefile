njobs ?= 10

runpt2pt:
	qsub -l  select=2:ncpus=128:mpiprocs=128:mem=200G round_robin.pbs
	qsub -l  select=4:ncpus=128:mpiprocs=128:mem=200G round_robin.pbs
	qsub -l  select=8:ncpus=128:mpiprocs=128:mem=200G round_robin.pbs
	qsub -l  select=10:ncpus=128:mpiprocs=128:mem=200G round_robin.pbs
	qsub -l  select=20:ncpus=128:mpiprocs=128:mem=200G round_robin.pbs
	qsub -l  select=40:ncpus=128:mpiprocs=128:mem=200G round_robin.pbs
	qsub -l  select=20:ncpus=128:mpiprocs=64:mem=200G round_robin.pbs
	qsub -l  select=40:ncpus=128:mpiprocs=32:mem=200G round_robin.pbs
	qsub -l  select=80:ncpus=128:mpiprocs=16:mem=200G round_robin.pbs
	qsub -l  select=160:ncpus=128:mpiprocs=8:mem=200G round_robin.pbs
	qsub -l  select=160:ncpus=128:mpiprocs=16:mem=200G round_robin.pbs
	qsub -l  select=160:ncpus=128:mpiprocs=32:mem=200G round_robin.pbs
	qsub -l  select=256:ncpus=128:mpiprocs=1:mem=200G round_robin.pbs

runalltoall:
	for nn in 2 4 8 16 32 64 128 256; do \
	  for ppn in 4 8 16 32 64 128; do \
	    qsub -l select=$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=200G alltoall.pbs ; \
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

netgauge/$(NCAR_BUILD_ENV):
	top_dir=$$(pwd) ; \
	mkdir -p $${top_dir}/netgauge && cd $${top_dir}/netgauge ; \
	[ -d netgauge-2.4.6 ] || curl -sL https://htor.inf.ethz.ch/research/netgauge/netgauge-2.4.6.tar.gz | tar xz ; \
	cd $${top_dir}/netgauge/netgauge-2.4.6 ; \
	$${top_dir}/netgauge/netgauge-2.4.6/configure HRT_ARCH=6 --prefix=$${top_dir}/$@ ; \
	make && make install

clean:
	rm -f log-* *~ *.pbs.o* nr*.log

qdelall:
	qdel $$(qstat -u $${USER} 2>/dev/null | grep ".desched" | egrep "round|alltoall|stressng" | cut -d'.' -f1)


results-pt2pt:
	for file in pt2pt-nr*.log; do \
	  stub=$$(echo $${file} | cut -d'.' -f1) ; \
	  [ -f $${file} ] && echo $${file} || continue ; \
	  grep "# --> END execution" $${file} >/dev/null 2>&1 || continue ; \
	  awk '/# --> BEGIN execution/{flag=1;next}/# --> END execution/{flag=0}flag' $${file} > $${file}.csv ; \
	  sed -i 's/Global Rank/# Global Rank/g' $${file}.csv ; \
	  cp $${file}.csv results-$${stub}.latest.csv ; \
	done
	grep "Slowest" pt2pt-nr*.log

results-alltoall:
	grep "avg_time" alltoall-nr*.log
	grep "Slowest" alltoall-nr*.log
