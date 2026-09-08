#include "LonghaulSupport.h"
#include <libproc.h>
uint64_t longhaul_process_birth(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}
pid_t longhaul_parent_pid(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return info.pbi_ppid;
}
int longhaul_process_path(pid_t pid, void *buffer, uint32_t size) { return proc_pidpath(pid, buffer, size); }
