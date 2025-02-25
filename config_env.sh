module --force purge
module load ncarenv/24.12
#module reset
#module load peak-memusage
#module list
#module load osu-micro-benchmarks



module load gcc ncarcompilers cuda
PATH=/glade/work/benkirk/test-stack/gust-gcc-12.4.0/bin:$PATH
export TESTS_DIR="/glade/work/benkirk/test-stack/omb-7.5"
export TMPDIR=/var/tmp/
export NCAR_BUILD_ENV="${NCAR_BUILD_ENV}-openmpi-5.0.7-test"

module list
echo "mpiexec=$(which mpiexec)"
echo "mpicxx=$(which mpicxx)"
