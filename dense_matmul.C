#include "mpi.h"
#include <vector>
#include <set>
#include <sstream>
#include <iostream>
#include <iomanip>
#include <limits>
#include <algorithm>
#include <assert.h>
#include <unistd.h>
#include <Eigen/Core>
#include <Eigen/Dense>

namespace {

  int nranks, myrank, nlocalranks, mylocalrank;

  const std::size_t
    maxstep = 12,
    matsize = 1024*8;

  const double
    slow_threshold = 1.05,
    maxtime_global = 60.*20.;
}



double dense_matmul (const std::size_t N)
{
  const double starttime = MPI_Wtime();

  typedef Eigen::Matrix<double, Eigen::Dynamic, Eigen::Dynamic> Matrix;

  const double t_tot_start = MPI_Wtime();

  Matrix A = Matrix::Random(N,N);

  const double t_ops_start = MPI_Wtime();

  Matrix A2 = A*A;

  const double
    t_end = MPI_Wtime(),
    FLOP  = static_cast<double>( N*N*(2*N - 1) ),
    FLOPS = FLOP / (t_end - t_ops_start);

  //std::cout << "# Total time: "      << (t_end - t_tot_start) << "\n";
  //std::cout << "# Operations time: " << (t_end - t_ops_start) << "\n";
  if (0 == myrank) std::cout << "# GFLOPS: " << FLOPS / 1.e9 << "\n";

  const double endtime = (MPI_Wtime() - starttime);

  return FLOPS;
}



double dense_solve (const std::size_t matsize)
{
  return;
  const double starttime = MPI_Wtime();

  {
    Eigen::MatrixXf A = Eigen::MatrixXf::Random(matsize, matsize);
    //std::cout << "Here is the matrix A:\n" << A << std::endl;
    Eigen::VectorXf xtrue = Eigen::VectorXf::Random(matsize);

    Eigen::VectorXf
      b = A*xtrue,
      xlu = A.lu().solve(b);

    if (0 == myrank) std::cout << "# Dense Solve Relative Error: " << (A*xlu - b).norm() / b.norm() << "\n";
    //std::cout << "Here is the right hand side b:\n" << b << std::endl;
  }

  const double endtime = (MPI_Wtime() - starttime);

  return endtime;
}



int main (int argc, char **argv)
{
  //omp_set_num_threads(MT);
  //Eigen::setNbThreads(MT);

  std::set<std::string> unique_hosts;

  MPI_Init (&argc, &argv);
  MPI_Comm_size (MPI_COMM_WORLD, &nranks);
  MPI_Comm_rank (MPI_COMM_WORLD, &myrank);

  std::vector<char> hns(64*nranks);

  MPI_Comm shmcomm;
  {
    MPI_Comm_split_type(MPI_COMM_WORLD, MPI_COMM_TYPE_SHARED, 0,
                        MPI_INFO_NULL, &shmcomm);
    MPI_Comm_size(shmcomm, &nlocalranks);
    MPI_Comm_rank(shmcomm, &mylocalrank);

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
                  << "# nranks/node = " << nlocalranks << "\n"
                  << "# nnodes = " << unique_hosts.size() << "\n"
                  << "# OMP threads = " << omp_get_num_threads() << "\n"
                  << "# Eigen::nbThreads() = " << Eigen::nbThreads() << "\n"
                  << "# MPI_Wtick() = " << MPI_Wtick() << "\n"
                  << "# omp_get_wtick() = " << omp_get_wtick() << "\n"
                  << "# *** running for walltime=" << maxtime_global << " (sec) or nsteps=" << maxstep << " (whichever first). ***\n";

        // for (unsigned int idx=0, cnt=0; cnt<nranks; cnt++, idx+=64)
        //   {
        //     std::cout << std::string(&hns[idx]);

        //     (cnt != (nranks-1)) ? std::cout << ", " : std::cout << "\n";
        //   }
        std::cout << "# unique hosts (" << unique_hosts.size() << "): ";
        for (auto it=unique_hosts.begin(); it!=unique_hosts.end(); ++it)
          std::cout << *it << " ";
        std::cout << "\n";
        std::cout << "# matsize = " << matsize << " (elements)" << std::endl;
      }
  }

  //----------------------------------------------------------------
  std::vector<float> mytimes; /**/ mytimes.reserve(maxstep);
  std::vector<float> myflops; /**/ myflops.reserve(maxstep);
  double
    elapsedtime_global = 0,
    local_min_time = std::numeric_limits<double>::max(), local_min_flops=local_min_time,
    local_max_time = 0., local_max_flops=local_max_time,
    avg_time = 0.;

  std::size_t step=0;
  int all_done=0;

  MPI_Request barrier = MPI_REQUEST_NULL;

  MPI_Barrier(MPI_COMM_WORLD);

  //----------------------------------------------------------------
  // average loop
  const double starttime_global = MPI_Wtime();

  while ((++step < maxstep) && (all_done == 0))
    {
      const double starttime_step = MPI_Wtime();

      dense_solve(matsize);
      const double flops = dense_matmul(matsize);

      // update timers & averages for this step
      const double elapsedtime_step = (MPI_Wtime() - starttime_step);

      elapsedtime_global = (MPI_Wtime() - starttime_global);

      avg_time = elapsedtime_global / static_cast<double>(step);

      local_min_time = std::min(local_min_time, elapsedtime_step);
      local_max_time = std::max(local_max_time, elapsedtime_step);

      local_min_flops = std::min(local_min_flops, flops);
      local_max_flops = std::max(local_max_flops, flops);

      mytimes.push_back(elapsedtime_step);
      myflops.push_back(flops);

      // start nonblocking barrier if we've exceeded maxtime_global
      if (elapsedtime_global > maxtime_global)
        {
          if (MPI_REQUEST_NULL == barrier)
            MPI_Ibarrier (MPI_COMM_WORLD, &barrier);

          MPI_Test (&barrier, &all_done, MPI_STATUS_IGNORE);
        }
    }
  //----------------------------------------------------------------

  {
    std::vector<double> avgtimes(nranks);
    double myavg = avg_time, allavg=0;
    MPI_Allgather(&myavg,       1, MPI_DOUBLE,
                  &avgtimes[0], 1, MPI_DOUBLE,
                  MPI_COMM_WORLD);
    for (unsigned int r=0; r<nranks; r++)
      allavg += avgtimes[r];

    allavg /= static_cast<double>(nranks);

    if (myavg > slow_threshold*allavg)
      std::cout << "# *** " << std::string(&hns[myrank*64]) << " SLOW: "
                << myavg << ", " << allavg << ", (" << myavg/allavg << ") ***\n";
  }

  if (0 == myrank)
    {
      std::cout << "ranks_nodes_ppn=("
                << nranks << ","
                << unique_hosts.size() << ","
                << nlocalranks << ")\n";
      std::cout << "all_steps=np.array([";
      for (auto it = mytimes.begin(); it!=mytimes.end(); ++it)
        std::cout << *it << ", ";
      std::cout << "])\n";
    }

  std::sort(mytimes.begin(), mytimes.end());
  std::sort(myflops.begin(), myflops.end());

  // get global slowest step
  double global_min_time = local_min_time;
  double global_max_time = local_max_time;

  MPI_Allreduce(&local_min_time, &global_min_time, 1, MPI_DOUBLE, MPI_MIN, MPI_COMM_WORLD);
  MPI_Allreduce(&local_max_time, &global_max_time, 1, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);

  // // optional: present slowest steps for each rank.
  // // (should be consistent, mostly this is just to double check.
  // for (unsigned int r=0; r<nranks; r++)
  //   {
  //     if (r == myrank)
  //       {
  //         int cnt=0;
  //         std::cout << "# rank " << myrank << " / " << hns[64*r] << " slowest steps: ";
  //         for (auto it = mytimes.rbegin(); it!=mytimes.rend(); ++it)
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
                << "# OMP threads = " << omp_get_num_threads() << "\n"
                << "# total steps = " << step <<"\n";


      int cnt=0;
      std::cout << "# my slowest steps (sec): ";
      for (auto it = mytimes.rbegin(); it!=mytimes.rend(); ++it)
        {
          if (cnt++ == 10) break;
          std::cout << *it << " (" << *it / avg_time << ") ";
        }
      std::cout << "\n";
      cnt=0;
      std::cout << "# my fastest steps (sec): ";
      for (auto it = mytimes.begin(); it!=mytimes.end(); ++it)
        {
          if (cnt++ == 10) break;
          std::cout << *it << " (" << *it / avg_time << ") ";
        }
      std::cout << "\n";
      cnt=0;
      std::cout << "# my slowest steps (GFLOPs): ";
      for (auto it = myflops.rbegin(); it!=myflops.rend(); ++it)
        {
          if (cnt++ == 10) break;
          std::cout << *it / 1.e9 << " ";
        }
      std::cout << "\n";
      cnt=0;
      std::cout << "# my fastest steps (GFLOPs): ";
      for (auto it = myflops.begin(); it!=myflops.end(); ++it)
        {
          if (cnt++ == 10) break;
          std::cout << *it / 1.e9 << " ";
        }
      std::cout << "\n";
      std::cout << "# --> END execution" << std::endl;
    }

  MPI_Comm_free(&shmcomm);
  MPI_Finalize();

  return 0;
}
