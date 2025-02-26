
module --force purge
module load ncarenv/24.12

testenv="test"

if [[ "${testenv}" == "test" ]]; then
    module load gcc ncarcompilers cuda
    PATH=/glade/work/benkirk/test-stack/gust-gcc-12.4.0/bin:$PATH
    export TESTS_DIR="/glade/work/benkirk/test-stack/omb-7.5"
    export TMPDIR=/var/tmp/
    export NCAR_BUILD_ENV="${NCAR_BUILD_ENV}-openmpi-5.0.7-test"
    export LMOD_FAMILY_MPI="openmpi"
else
    module reset
    module load peak-memusage
    module load osu-micro-benchmarks
fi

module list
echo "mpiexec=$(which mpiexec)"
echo "mpicxx=$(which mpicxx)"
