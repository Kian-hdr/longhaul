#include <stdint.h>
#include <sys/types.h>
uint64_t longhaul_process_birth(pid_t pid);
pid_t longhaul_parent_pid(pid_t pid);
int longhaul_process_path(pid_t pid, void *buffer, uint32_t size);

/* Bounded libproc metadata only. No process environment or file content access. */
#define LONGHAUL_DISCOVERY_PATH_CAPACITY 4096
#define LONGHAUL_DISCOVERY_UNAVAILABLE 1u
#define LONGHAUL_DISCOVERY_TRUNCATED 2u
#define LONGHAUL_DISCOVERY_CHANGED 4u
#define LONGHAUL_DISCOVERY_TIMED_OUT 8u
#define LONGHAUL_DISCOVERY_ITEM_ERROR 16u
struct longhaul_discovery_result {
    uint32_t status;
    int32_t error_code;
    uint32_t count;
    uint32_t examined;
};
struct longhaul_process_metadata {
    int32_t pid;
    int32_t parent_pid;
    uint64_t birth;
    uint32_t uid;
    char executable_path[LONGHAUL_DISCOVERY_PATH_CAPACITY];
};
struct longhaul_open_file_metadata {
    int32_t fd;
    uint32_t open_flags;
    uint32_t writable;
    uint32_t device;
    uint64_t inode;
    uint32_t owner_uid;
    uint16_t mode;
    int64_t size;
    int64_t modified_seconds;
    int64_t modified_nanoseconds;
    char path[LONGHAUL_DISCOVERY_PATH_CAPACITY];
};
struct longhaul_discovery_result longhaul_user_processes(int32_t *pids, uint32_t capacity);
int32_t longhaul_inspect_process(int32_t pid, struct longhaul_process_metadata *metadata);
struct longhaul_discovery_result longhaul_process_open_files(int32_t pid, uint64_t expected_birth,
    uint32_t maximum_fds, struct longhaul_open_file_metadata *files, uint32_t capacity, uint32_t budget_milliseconds);
