		Examples
=================================================

This is a collection of example scripts to help with running dgnettest in ways other than via slurm on cray OS. The script dgnettest_run.sh is set up to run dgnettest over slurm and in interactive mode. Typically, on systems running the cray-mpich, Slurm will have support for MPI integrated into it and you could just execute the dgnettest_run.sh script to test across all nodes. While running on systems not setup in this configuration isn't explicitly supported, dgnettest is able to be run on other systems so long as cray-mpich is available on the system. The example scripts provided are scripts that others have used and shared with the development team. The hope is by using these examples, you can modify the included scripts to support your system configuration for testing the slingshot fabric.


		dgnettest-pbs.job
----------------------------------------------------
This script helps to provide examples on how to run dgnettest on PBS, with a batch script, and using mpiexec. This test will read in a selection of nodes from a file and then run dgnettest's bisectional test 
