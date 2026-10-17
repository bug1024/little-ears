#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

// Kernel per-process counters. No root, task_for_pid or Accessibility permission required.
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: sample-process PID\n"); return 2; }
    int pid = atoi(argv[1]);
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    double tick_ns = (double)timebase.numer / timebase.denom;
    printf("wall_s,user_ns,system_ns,rss_bytes,footprint_bytes,max_footprint_bytes,interrupt_wakeups,package_idle_wakeups,pageins,read_bytes,write_bytes,kernel_energy_nj,rusage_version\n");
    for (;;) {
        struct rusage_info_v6 info = {0};
        int version = RUSAGE_INFO_V6;
        if (proc_pid_rusage(pid, version, (rusage_info_t *)&info) != 0) {
            version = RUSAGE_INFO_V4;
            if (proc_pid_rusage(pid, version, (rusage_info_t *)&info) != 0) return 0;
        }
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
        printf("%.6f,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%d\n",
               ts.tv_sec + ts.tv_nsec / 1e9,
               (uint64_t)(info.ri_user_time * tick_ns), (uint64_t)(info.ri_system_time * tick_ns), info.ri_resident_size, info.ri_phys_footprint,
               info.ri_lifetime_max_phys_footprint, info.ri_interrupt_wkups, info.ri_pkg_idle_wkups,
               info.ri_pageins, info.ri_diskio_bytesread, info.ri_diskio_byteswritten,
               version == RUSAGE_INFO_V6 ? info.ri_energy_nj : 0, version);
        fflush(stdout);
        struct timespec delay = {1, 0}; nanosleep(&delay, NULL);
    }
}
