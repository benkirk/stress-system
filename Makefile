njobs ?= 10
queue ?= system
qsub ?= qsub

#	for nn in 2048 1536 1024 512; do \
# 	for nn in 2 4 8 16 32 64 128 256 384 512; do \

runstartup:
	for nn in 1024 768 512 384 256 128 64 32 16 8 4 2 1; do \
	  for ppn in 128; do \
	    for try in 0 1 2 3; do \
	      ss="$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=235G" && echo $${ss} && $(qsub) -q $(queue) -l select=$${ss} startup.pbs ; \
	    done ; \
	  done ; \
	done

runpt2pt:
	for nn in 2 4 8 16 32 64 96 128; do \
	  for ppn in 1 8 16 32 64 120 128; do \
	    ss="$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=235G" && echo $${ss} && $(qsub) -q $(queue) -l select=$${ss} round_robin.pbs ; \
	  done ; \
	done

run%:
	for nn in 2 4 8 16 32 64 96 128 256 384 512 768 1024; do \
	  for ppn in 4 8 16 32 64 128; do \
	    ss="$${nn}:ncpus=128:mpiprocs=$${ppn}:mem=235G" && echo $${ss} && $(qsub) -q $(queue) -l select=$${ss} $*.pbs ; \
	  done ; \
	done

runmany: stress-ng/stress-ng
	for j in $$(seq 1 $(njobs)); do \
	  echo -n "submitting job #$$j: " ; \
	  $(qsub) -q $(queue) ./stressng_test.pbs ; if [ $$(($$j%10)) -eq 0 ]; then sleep 1s; fi ; \
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
	for file in pt2pt-nr*.log.xz; do \
	  ls -lh $${file} ; \
	  stub=$$(echo $${file} | cut -d'.' -f1) ; \
	  csv=$${file/".log.xz"/".csv.xz"} ; \
	  xzgrep "# --> END execution" $${file} >/dev/null 2>&1 || continue ; \
	  xzcat $${file} | awk '/# --> BEGIN execution/{flag=1;next}/# --> END execution/{flag=0}flag' | xz > $${csv} ; \
	  echo " not ..." cp $${file} $${csv} ; \
	  cp $${csv} results-$${stub}.latest.csv.xz ; \
	done
	xzgrep "MPICH Slingshot Network Summary" pt2pt-nr*.log.xz | grep -v "0 network timeouts" || true
	xzgrep "Slowest" pt2pt-nr*.log.xz

results-all%:
	for file in all$*-nr*.log.xz; do \
	  ls -lh $${file} ; \
	  stub=$$(echo $${file} | cut -d'.' -f1) ; \
	  txt=$${file/".log.xz"/".txt.xz"} ; \
	  xzgrep "# --> END execution" $${file} >/dev/null 2>&1 || continue ; \
	  xzcat $${file} | awk '/# --> BEGIN execution/{flag=1;next}/# --> END execution/{flag=0}flag' | xz > $${txt} ; \
	  cp $${txt} results-$${stub}.latest.txt.xz ; \
	done
	xzgrep "MPICH Slingshot Network Summary" all$*-nr*.log.xz | grep -v "0 network timeouts" || true
	xzgrep "avg_time" all$*-nr*.log.xz
	xzgrep "Slowest" all$*-nr*.log.xz

results-failures:
	@pwd
	@egrep "launch failed|RPC timeout|LAUNCH FAILURE" *.pbs.o* | grep -v "+ echo" | sort | uniq  # | cut -d ':' -f2

archive_results:
	timestamp=$$(date +%F@%H:%M) ; \
	mkdir -p logs/$${timestamp} ; \
	mv startup*-*.log *-*.log.* *.pbs.o* logs/$${timestamp} || true; \
	mv *-*.*.xz logs/$${timestamp} || true
