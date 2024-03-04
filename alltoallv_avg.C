#include "mpi.h"
#include <vector>
#include <set>
#include <sstream>
#include <iostream>
#include <iomanip>
#include <limits>
#include <algorithm>
#include <numeric>
#include <assert.h>
#include <unistd.h>



int main (int argc, char **argv)
{
  int nranks, myrank, nlocalranks, mylocalrank;

  const std::size_t
    bufcnt =  1000,
    bufsize = bufcnt*(sizeof(unsigned int)),
    maxstep = 5e2;
  assert (bufcnt > 8);

  const double maxtime_global = 60.*10.;
  std::set<std::string> unique_hosts;

  MPI_Init (&argc, &argv);
  MPI_Comm_size (MPI_COMM_WORLD, &nranks);
  MPI_Comm_rank (MPI_COMM_WORLD, &myrank);

  std::vector<char> hns(64*nranks);

  {
    MPI_Comm shmcomm;
    MPI_Comm_split_type(MPI_COMM_WORLD, MPI_COMM_TYPE_SHARED, 0,
                        MPI_INFO_NULL, &shmcomm);
    MPI_Comm_size(shmcomm, &nlocalranks);
    MPI_Comm_rank(shmcomm, &mylocalrank);
    MPI_Comm_free(&shmcomm);

    char hn[64];
    gethostname(hn, sizeof(hn) / sizeof(char));

    // first step - undecorated hostnames
    MPI_Allgather(&hn[0],  64, MPI_CHAR,
                  &hns[0], 64, MPI_CHAR,
                  MPI_COMM_WORLD);

    for (auto r=0; r<nranks; r++)
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
                  << "# nranks/node = " << nlocalranks << "\n"
                  << "# nnodes = " << unique_hosts.size() << "\n"
                  << "# MPI_Wtick() = " << MPI_Wtick() << "\n";

        std::cout << "# unique hosts (" << unique_hosts.size() << "): ";
        for (auto it=unique_hosts.begin(); it!=unique_hosts.end(); ++it)
          std::cout << *it << " ";
        std::cout << "\n";

        std::cout << "# bufcnt  = " << bufcnt  << " (elements)\n"
                  << "# bufsize = " << bufsize << " (bytes)" << std::endl;
      }
  }

  //----------------------------------------------------------------
  std::vector<unsigned int> sbuf(nranks*bufcnt), rbuf(nranks*bufcnt);
  std::vector<int> sendcounts(/* size = */ nranks, /* value = */ bufcnt);
  std::vector<int> sdispls   (/* size = */ nranks, /* value = */ 0);
  std::vector<int> recvcounts(/* size = */ nranks, /* value = */ -1);
  std::vector<int> rdispls   (/* size = */ nranks, /* value = */ -1);

  {
    std::partial_sum(sendcounts.begin(), sendcounts.end(), sdispls.begin());
    for (std::vector<int>::iterator it=sdispls.begin(); it!=sdispls.end(); ++it)
      *it -= bufcnt;

    rdispls = sdispls;

    // even ranks receive full bufcnt; odd ranks 1/2 that.
    for (auto r=0; r<sendcounts.size(); ++r)
      {
        sendcounts[r] = (0 == r%2)      ? bufcnt : bufcnt/2;
        recvcounts[r] = (0 == myrank%2) ? bufcnt : bufcnt/2;
      }
  }

  std::vector<float> myresults; /**/ myresults.reserve(maxstep);
  double
    elapsedtime_global = 0,
    local_min_time = std::numeric_limits<double>::max(),
    local_max_time = 0.,
    avg_time = 0.;

  std::size_t step=0;
  int all_done=0;

  MPI_Request barrier = MPI_REQUEST_NULL;

  // make sure this is truly allocated before beginning by touching all elements
  std::fill (sbuf.begin(), sbuf.end(), myrank);

  MPI_Barrier(MPI_COMM_WORLD);

  //----------------------------------------------------------------
  // average loop
  const double starttime_global = MPI_Wtime();

  while ((++step < maxstep) && (all_done == 0))
    {
      std::fill (sbuf.begin(), sbuf.end(), step*nranks + myrank);
      std::fill (rbuf.begin(), rbuf.end(), 0); // <-- initialize invalid

      const double starttime_step = MPI_Wtime();

      MPI_Alltoallv (&sbuf[0], &sendcounts[0], &sdispls[0], MPI_UNSIGNED,
                     &rbuf[0], &recvcounts[0], &rdispls[0], MPI_UNSIGNED,
                     MPI_COMM_WORLD);

      // update timers & averages for this step
      const double elapsedtime_step = (MPI_Wtime() - starttime_step);

      elapsedtime_global = (MPI_Wtime() - starttime_global);

      avg_time = elapsedtime_global / static_cast<double>(step);

      local_min_time = std::min(local_min_time, elapsedtime_step);
      local_max_time = std::max(local_max_time, elapsedtime_step);

      myresults.push_back(elapsedtime_step);

      // start nonblocking barrier if we've exceeded maxtime_global
      if (elapsedtime_global > maxtime_global)
        {
          if (MPI_REQUEST_NULL == barrier)
            MPI_Ibarrier (MPI_COMM_WORLD, &barrier);

          MPI_Test (&barrier, &all_done, MPI_STATUS_IGNORE);
        }

      // check correctness (first few elem)
      for (auto r=0, idx=0; r<nranks; r++, idx+=bufcnt)
        {
          assert(rdispls[r] == sdispls[r]);
          for (auto c=0; c<std::min(4,(int)bufcnt); c++)
            assert(rbuf[idx+c] == (step*nranks + r));
        }
    }
  //----------------------------------------------------------------

  if (0 == myrank)
    {
      std::cout << "ranks_nodes_ppn=("
                << nranks << ","
                << unique_hosts.size() << ","
                << nlocalranks << ")\n";
      std::cout << "all_steps=np.array([";
      for (auto it = myresults.begin(); it!=myresults.end(); ++it)
        std::cout << *it << ", ";
      std::cout << "])\n";
    }

  std::sort(myresults.begin(), myresults.end());

  // get global slowest step
  double global_min_time = local_min_time;
  double global_max_time = local_max_time;

  MPI_Allreduce(&local_min_time, &global_min_time, 1, MPI_DOUBLE, MPI_MIN, MPI_COMM_WORLD);
  MPI_Allreduce(&local_max_time, &global_max_time, 1, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);

  // // optional: present slowest steps for each rank.
  // // (should be consistent, mostly this is just to double check.
  // for (auto r=0; r<nranks; r++)
  //   {
  //     if (r == myrank)
  //       {
  //         int cnt=0;
  //         std::cout << "# rank " << myrank << " / " << hns[64*r] << " slowest steps: ";
  //         for (auto it = myresults.rbegin(); it!=myresults.rend(); ++it)
  //           {
  //             if (cnt++ == 10) break;
  //             std::cout << *it << " (" << *it / avg_time << ") ";
  //           }
  //         std::cout << std::endl;
  //       }
  //     MPI_Barrier(MPI_COMM_WORLD);
  //   }

  if (0 == myrank)
    {
      std::cout << "# Elapsed Time = " << elapsedtime_global << " (sec)\n"
                << "# Fastest Step: t_min = " << global_min_time << " (sec)\n"
                << "# Slowest Step: t_max = " << global_max_time << " (sec)\n"
                << "# avg_time = " << avg_time << " (sec)\n"
                << "# total steps = " << step <<"\n";


      int cnt=0;
      std::cout << "# my slowest steps: ";
      for (auto it = myresults.rbegin(); it!=myresults.rend(); ++it)
        {
          if (cnt++ == 10) break;
          std::cout << *it << " (" << *it / avg_time << ") ";
        }

      std::cout << "\n# --> END execution" << std::endl;
    }

  MPI_Finalize();

  return 0;
}
