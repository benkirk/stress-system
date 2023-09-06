#include <iostream>
#include <iomanip>
#include <unistd.h>
#include "mpi.h"



int main (int argc, char **argv)
{
  int numprocs, rank;
  char hn[256];

  gethostname(hn, sizeof(hn) / sizeof(char));

  MPI_Init(&argc, &argv);

  MPI_Comm_size (MPI_COMM_WORLD, &numprocs);
  MPI_Comm_rank (MPI_COMM_WORLD, &rank);

  if (0 == rank)
    std::cout << "Hello from " << std::setw(3) << rank
              << " / " << std::string (hn)
              << ", running " << argv[0] << " on "
              << std::setw(3) << numprocs << " rank(s)"
              << std::endl;

  MPI_Finalize();

  return 0;
}
