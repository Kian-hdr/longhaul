#include "LonghaulSupport.h"
#include <errno.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static double monotonic_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0) return -1;
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}
static int checked_path(const char *path, size_t capacity) {
    size_t length = strnlen(path, capacity);
    return length > 0 && length < capacity && path[0] == '/';
}
int32_t longhaul_inspect_process(int32_t pid, struct longhaul_process_metadata *out) {
    if (pid <= 0 || out == NULL) return EINVAL;
    memset(out, 0, sizeof(*out));
    struct proc_bsdinfo before, after;
    errno = 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before)) return errno ? errno : EIO;
    if (before.pbi_uid != getuid()) return EACCES;
    if (proc_pidpath(pid, out->executable_path, sizeof(out->executable_path)) <= 0) return errno ? errno : EIO;
    if (!checked_path(out->executable_path, sizeof(out->executable_path))) return EIO;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after)) return errno ? errno : EIO;
    if (before.pbi_start_tvsec != after.pbi_start_tvsec || before.pbi_start_tvusec != after.pbi_start_tvusec ||
        before.pbi_ppid != after.pbi_ppid || before.pbi_uid != after.pbi_uid) return ESTALE;
    out->pid = pid; out->parent_pid = before.pbi_ppid; out->uid = before.pbi_uid;
    out->birth = before.pbi_start_tvsec * 1000000ULL + before.pbi_start_tvusec;
    return out->birth ? 0 : EIO;
}
struct longhaul_discovery_result longhaul_user_processes(int32_t *pids, uint32_t capacity) {
    struct longhaul_discovery_result result = {0};
    if (!pids || capacity == 0 || capacity > 8192) {
        result.status = LONGHAUL_DISCOVERY_UNAVAILABLE; result.error_code = EINVAL; return result;
    }
    int available = proc_listpids(PROC_UID_ONLY, getuid(), NULL, 0);
    errno = 0;
    int count = proc_listpids(PROC_UID_ONLY, getuid(), pids, (int)(capacity * sizeof(*pids)));
    if (count <= 0 || count % sizeof(*pids)) {
        result.status = LONGHAUL_DISCOVERY_UNAVAILABLE; result.error_code = errno ? errno : EIO; return result;
    }
    result.count = (uint32_t)count / sizeof(*pids); result.examined = result.count;
    if (available > (int)(capacity * sizeof(*pids)) || result.count >= capacity) result.status |= LONGHAUL_DISCOVERY_TRUNCATED;
    return result;
}
static int same_file(const struct vnode_fdinfowithpath *a, const struct vnode_fdinfowithpath *b) {
    return a->pvip.vip_vi.vi_stat.vst_dev == b->pvip.vip_vi.vi_stat.vst_dev &&
        a->pvip.vip_vi.vi_stat.vst_ino == b->pvip.vip_vi.vi_stat.vst_ino &&
        a->pvip.vip_vi.vi_stat.vst_mode == b->pvip.vip_vi.vi_stat.vst_mode &&
        a->pfi.fi_openflags == b->pfi.fi_openflags && strcmp(a->pvip.vip_path, b->pvip.vip_path) == 0;
}
struct longhaul_discovery_result longhaul_process_open_files(int32_t pid, uint64_t expected_birth,
        uint32_t maximum_fds, struct longhaul_open_file_metadata *files, uint32_t capacity, uint32_t budget_ms) {
    struct longhaul_discovery_result result = {0};
    if (pid <= 0 || !expected_birth || !files || !capacity || capacity > 2048 ||
        !maximum_fds || maximum_fds > 16384 || !budget_ms || budget_ms > 2000) {
        result.status = LONGHAUL_DISCOVERY_UNAVAILABLE; result.error_code = EINVAL; return result;
    }
    struct longhaul_process_metadata before, after;
    int error = longhaul_inspect_process(pid, &before);
    if (error || before.birth != expected_birth) {
        result.status = error ? LONGHAUL_DISCOVERY_UNAVAILABLE : LONGHAUL_DISCOVERY_CHANGED;
        result.error_code = error ? error : ESTALE; return result;
    }
    double started = monotonic_seconds();
    if (started < 0) { result.status = LONGHAUL_DISCOVERY_UNAVAILABLE; result.error_code = EIO; return result; }
    struct proc_fdinfo *fds = calloc(maximum_fds, sizeof(*fds));
    if (!fds) { result.status = LONGHAUL_DISCOVERY_UNAVAILABLE; result.error_code = ENOMEM; return result; }
    errno = 0;
    int available = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    int count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, (int)(maximum_fds * sizeof(*fds)));
    if (count < 0 || (count == 0 && errno) || count % sizeof(*fds)) {
        result.status = LONGHAUL_DISCOVERY_UNAVAILABLE; result.error_code = errno ? errno : EIO;
        free(fds); return result;
    }
    uint32_t fd_count = (uint32_t)count / sizeof(*fds);
    if (available > (int)(maximum_fds * sizeof(*fds)) || fd_count >= maximum_fds) result.status |= LONGHAUL_DISCOVERY_TRUNCATED;
    for (uint32_t i = 0; i < fd_count; i++) {
        double now = monotonic_seconds();
        if (now < started || now - started > (double)budget_ms / 1000) { result.status |= LONGHAUL_DISCOVERY_TIMED_OUT; break; }
        result.examined++;
        if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
        struct vnode_fdinfowithpath first, second;
        memset(&first, 0, sizeof(first)); memset(&second, 0, sizeof(second));
        errno = 0;
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &first, sizeof(first)) != sizeof(first)) {
            result.status |= LONGHAUL_DISCOVERY_ITEM_ERROR; if (!result.error_code) result.error_code = errno ? errno : EIO; continue;
        }
        if (!S_ISREG(first.pvip.vip_vi.vi_stat.vst_mode)) continue;
        if (!checked_path(first.pvip.vip_path, sizeof(first.pvip.vip_path))) { result.status |= LONGHAUL_DISCOVERY_ITEM_ERROR; continue; }
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &second, sizeof(second)) != sizeof(second) ||
            !checked_path(second.pvip.vip_path, sizeof(second.pvip.vip_path)) || !same_file(&first, &second)) {
            result.status |= LONGHAUL_DISCOVERY_CHANGED; continue;
        }
        if (result.count >= capacity) { result.status |= LONGHAUL_DISCOVERY_TRUNCATED; break; }
        struct longhaul_open_file_metadata *out = &files[result.count++];
        memset(out, 0, sizeof(*out));
        out->fd = fds[i].proc_fd; out->open_flags = second.pfi.fi_openflags;
        // libproc exports fileglob fg_flag, which uses FWRITE, not O_ACCMODE.
        out->writable = (second.pfi.fi_openflags & FWRITE) != 0;
        out->device = second.pvip.vip_vi.vi_stat.vst_dev; out->inode = second.pvip.vip_vi.vi_stat.vst_ino;
        out->owner_uid = second.pvip.vip_vi.vi_stat.vst_uid; out->mode = second.pvip.vip_vi.vi_stat.vst_mode;
        out->size = second.pvip.vip_vi.vi_stat.vst_size;
        out->modified_seconds = second.pvip.vip_vi.vi_stat.vst_mtime;
        out->modified_nanoseconds = second.pvip.vip_vi.vi_stat.vst_mtimensec;
        strlcpy(out->path, second.pvip.vip_path, sizeof(out->path));
    }
    free(fds);
    error = longhaul_inspect_process(pid, &after);
    if (error || after.birth != before.birth || after.parent_pid != before.parent_pid || strcmp(after.executable_path, before.executable_path)) {
        result.status |= LONGHAUL_DISCOVERY_CHANGED; result.error_code = error ? error : ESTALE;
        result.count = 0; // No ownership claim survives process/exec identity loss.
    }
    return result;
}
