#include "mpi.h"
#include <vector>
#include <set>
#include <sstream>
#include <iostream>
#include <iomanip>
#include <limits>
#include <assert.h>
#include <unistd.h>



int main (int argc, char **argv)
{
  int nranks, myrank, mylocalrank;

  const std::size_t
    itemsize = sizeof(unsigned int),
    bufcnt =  1000*1000 / itemsize,
    bufsize = bufcnt*itemsize,
    nrep = 4;

  std::set<std::string> unique_hosts;

  MPI_Init (&argc, &argv);
  MPI_Comm_size (MPI_COMM_WORLD, &nranks);
  MPI_Comm_rank (MPI_COMM_WORLD, &myrank);

  std::vector<char> hns(64*nranks);

  {
    MPI_Comm shmcomm;
    MPI_Comm_split_type(MPI_COMM_WORLD, MPI_COMM_TYPE_SHARED, 0,
                        MPI_INFO_NULL, &shmcomm);
    MPI_Comm_rank(shmcomm, &mylocalrank);
    MPI_Comm_free(&shmcomm);

    char hn[64];
    gethostname(hn, sizeof(hn) / sizeof(char));


    // first step - undecorated hostnames
    MPI_Allgather(&hn[0],  64, MPI_CHAR,
                  &hns[0], 64, MPI_CHAR,
                  MPI_COMM_WORLD);

    for (unsigned int r=0; r<nranks; r++)
      unique_hosts.insert(std::string(&hns[r*64]));

    // second step - "global_rank:hostname:local_rank"
    std::ostringstream oss;
    oss << myrank << ":" << hn << ":" << mylocalrank;
    std::string str = oss.str();
    assert (str.length() < 64);

    MPI_Allgather(&str[0], 64, MPI_CHAR,
                  &hns[0], 64, MPI_CHAR,
                  MPI_COMM_WORLD);


    if (0 == myrank)
      {
        time_t now = time(0);

        std::cout << "# --> BEGIN execution\n"
                  << "# " << ctime(&now)
                  << "# " << argv[0] << "\n"
                  << "# nranks = " << nranks << "\n"
                  << "# MPI_Wtick() = " << MPI_Wtick() << "\n";

        std::cout << "# unique hosts (" << unique_hosts.size() << "): ";
        for (auto it=unique_hosts.begin(); it!=unique_hosts.end(); ++it)
          std::cout << *it << " ";
        std::cout << "\n";

        std::cout << "# bufcnt  = " << bufcnt  << " (elements)\n"
                  << "# bufsize = " << bufsize << " (bytes)\n";
        //          << "# myrank, procup, procdn=\n";
      }
  }

  std::vector<unsigned int> sbuf, rbufA(bufcnt,0), rbufB(bufcnt,0);
  sbuf.reserve(bufcnt);
  for (unsigned int i=myrank, j=0; j<bufcnt; i++, j++)
    sbuf.push_back(i);

  std::vector<float> recv(nranks,0.); // <-- timings buffer

  MPI_Request sreqs[2], rreqs[2];
  MPI_Status status;

  double local_t_min=std::numeric_limits<double>::max(), local_t_max=0.;

  for (unsigned int rc=0; rc<nranks; rc++)
    {
      const int
        procup = (nranks + myrank + rc) % nranks,
        procdn = (nranks + myrank - rc) % nranks;

      assert (procup >= 0 && procup < nranks);
      assert (procdn >= 0 && procdn < nranks);

      double total_elapsed=0.;

      // start the steps synchronized.
      // no special rank-0 stuff during timing loop.
      MPI_Barrier(MPI_COMM_WORLD);

      for (std::size_t step=0; step<nrep; ++step)
        {
          int idx=-1;
          const double starttime = MPI_Wtime();

          MPI_Isend(&sbuf[0],  bufcnt, MPI_UNSIGNED, procup, /* tag = */ step*nranks + rc, MPI_COMM_WORLD, &sreqs[0]);
          MPI_Isend(&sbuf[0],  bufcnt, MPI_UNSIGNED, procdn, /* tag = */ step*nranks + rc, MPI_COMM_WORLD, &sreqs[1]);
          MPI_Irecv(&rbufA[0], bufcnt, MPI_UNSIGNED, procdn, /* tag = */ step*nranks + rc, MPI_COMM_WORLD, &rreqs[0]);
          MPI_Irecv(&rbufB[0], bufcnt, MPI_UNSIGNED, procup, /* tag = */ step*nranks + rc, MPI_COMM_WORLD, &rreqs[1]);

          // First Irecv Completion - whichever rank
          MPI_Waitany(2, rreqs, &idx, &status);
          assert (status.MPI_SOURCE == procup || status.MPI_SOURCE == procdn);
          assert (idx == 0 || idx == 1);
          recv[status.MPI_SOURCE] += (MPI_Wtime() - starttime);

          // Second Irecv Completion - whichever rank
          idx = (idx+1)%2;
          MPI_Wait(&rreqs[idx], &status);
          assert (status.MPI_SOURCE == procup || status.MPI_SOURCE == procdn);
          recv[status.MPI_SOURCE] += (MPI_Wtime() - starttime);

          // Isend completions
          MPI_Waitall(2, sreqs, MPI_STATUSES_IGNORE);

          // update timers for this step,
          // after all nonblocking comm has completed.
          // keep track of per-rank fastest and slowest extremes
          const double elapsed = (MPI_Wtime() - starttime);
          local_t_min = std::min(local_t_min, elapsed);
          local_t_max = std::max(local_t_max, elapsed);
          total_elapsed += elapsed;

          // check correctness (first few elem)
          for (unsigned int i=procdn, j=procup, k=0; k<std::min((int)bufcnt,10); i++, j++, k++)
            {
              assert(rbufA[k] == i);
              assert(rbufB[k] == j);
            }
        } // end avg loop over nrep

      // compute average over nrep
      total_elapsed /= static_cast<double>(nrep);

      // if (0 == myrank)
      //   std::cout << "# "
      //             << std::setw(5) << myrank
      //             << ", " << std::setw(5) << procup
      //             << ", " << std::setw(5) << procdn
      //             << " / " << std::setw(12) << total_elapsed << "\t (sec)"
      //             << " / " << std::setw(12) << static_cast<double>(itemsize*bufsize) / total_elapsed << " (bytes/sec)\n";
    }

  // compute average over 2*nrep - in the ring above, we hit 2 pairs per loop
  for (unsigned int r=0; r<nranks; ++r)
    recv[r] /= static_cast<double>(2*nrep);

  // gather timing for all pairs
  {
    double global_t_max=local_t_max;

    MPI_Reduce(&local_t_max, &global_t_max, 1, MPI_DOUBLE, MPI_MAX, /* rank = */ 0, MPI_COMM_WORLD);

    // table header row
    if (0 == myrank)
      for (unsigned int cnt=0; cnt<nranks; cnt++)
        {
          std::cout << std::string(&hns[cnt*64]);
          (cnt != (nranks-1)) ? std::cout << ", " : std::cout << "\n";
        }

    // table rows
    for (unsigned int i=0; i<nranks; ++i)
      {
        if (0 == myrank)
          std::cout << std::string(&hns[i*64]) << ", ";

        // first row, i==0 --> myrank==0 and we have the data already,
        // else collect & overwrire recv[].
        if (0 != i)
          {
            if (i == myrank)
              MPI_Send(&recv[0], nranks, MPI_FLOAT, /* dest = */ 0, /* tag = */ 314159, MPI_COMM_WORLD);
            else if (0 == myrank)
              MPI_Recv(&recv[0], nranks, MPI_FLOAT, /* src = */  i, /* tag = */ 314159, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
          }

        // table columns
        if (0 == myrank)
          for (unsigned int j=0; j<nranks; ++j)
            {
              std::cout << std::setprecision(6) << recv[j];
              (j != (nranks-1)) ? std::cout << ", " : std::cout << "\n";
            }
      }

    if (0 == myrank)
      std::cout << "# Slowest Step: t_max = " << global_t_max << " (sec), "
                << static_cast<double>(itemsize*bufsize) / global_t_max <<  " (bytes/sec)\n"
                << "# --> END execution" << std::endl;
  }

  MPI_Finalize();

  return 0;
}
