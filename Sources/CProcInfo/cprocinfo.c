#include "cprocinfo.h"

#include <arpa/inet.h>
#include <libgen.h>
#include <libproc.h>
#include <netinet/in.h>
#include <netinet/tcp_fsm.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <unistd.h>

// Enumerate every visible PID via sysctl(KERN_PROC_ALL). proc_listallpids
// is heavily filtered on macOS 26 — it returns only ~15% of the PIDs `ps`
// sees, missing Electron apps (Cursor, Chrome), Claude Code, etc. — even
// though they're owned by the calling UID. KERN_PROC_ALL gives us the full
// list `ps`/`top` rely on. Caller must free the returned buffer.
static int *waik_list_pids(size_t *out_count) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0) return NULL;
    if (length == 0) return NULL;

    // Race-tolerant: the proc table can grow between the two sysctls.
    length += 64 * sizeof(struct kinfo_proc);
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(length);
    if (!procs) return NULL;
    if (sysctl(mib, 3, procs, &length, NULL, 0) != 0) {
        free(procs);
        return NULL;
    }
    size_t n = length / sizeof(struct kinfo_proc);

    int *pids = (int *)malloc(n * sizeof(int));
    if (!pids) { free(procs); return NULL; }
    for (size_t i = 0; i < n; i++) {
        pids[i] = procs[i].kp_proc.p_pid;
    }
    free(procs);
    *out_count = n;
    return pids;
}

// Resolve a process's comm name, normalizing version-numbered tool layouts
// (Claude Code, Codex) to their canonical name. Returns 1 on success.
static int waik_resolve_comm(pid_t pid, char *comm_out, size_t comm_cap) {
    char comm[WAIK_NAME_MAX];
    memset(comm, 0, sizeof(comm));
    struct proc_bsdshortinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    int sgot = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0,
                            &bsd, PROC_PIDT_SHORTBSDINFO_SIZE);
    if (sgot > 0 && bsd.pbsi_comm[0] != '\0') {
        strncpy(comm, bsd.pbsi_comm, sizeof(comm) - 1);
    }

    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    memset(pathbuf, 0, sizeof(pathbuf));
    int pn = proc_pidpath(pid, pathbuf, sizeof(pathbuf));

    if (comm[0] == '\0') {
        if (pn <= 0) return 0;
        char pathcopy[PROC_PIDPATHINFO_MAXSIZE];
        memcpy(pathcopy, pathbuf, sizeof(pathbuf));
        char *bname = basename(pathcopy);
        if (!bname || !*bname) return 0;
        strncpy(comm, bname, sizeof(comm) - 1);
    }
    if (comm[0] == '\0') return 0;

    if (pn > 0) {
        if (strstr(pathbuf, "/.local/share/claude/versions/")) {
            strncpy(comm, "claude", sizeof(comm) - 1);
            comm[sizeof(comm) - 1] = '\0';
        } else if (strstr(pathbuf, "/.local/share/codex/versions/")) {
            strncpy(comm, "codex", sizeof(comm) - 1);
            comm[sizeof(comm) - 1] = '\0';
        }
    }

    strncpy(comm_out, comm, comm_cap - 1);
    comm_out[comm_cap - 1] = '\0';
    return 1;
}

// Scan one PID's established TCP sockets into `out` starting at index `start`,
// returning the number of entries written. Used by both the full scan
// (waik_scan_connections) and the targeted re-probe path.
static size_t waik_scan_pid(pid_t pid,
                            const char *comm,
                            WaikConnection *out,
                            size_t start,
                            size_t out_capacity) {
    if (pid <= 0 || start >= out_capacity) return 0;

    int fd_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (fd_bytes <= 0) return 0;

    // Same trick as proc_listallpids: kernel's size estimate
    // under-allocates on macOS 26. Over-allocate for the actual fetch.
    int fd_buf = fd_bytes < (64 * 1024) ? (64 * 1024) : fd_bytes;
    struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)fd_buf);
    if (!fds) return 0;

    int actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, fd_buf);
    if (actual <= 0) { free(fds); return 0; }
    size_t fd_count = (size_t)actual / sizeof(struct proc_fdinfo);

    size_t written = 0;
    size_t cursor = start;

    for (size_t j = 0; j < fd_count && cursor < out_capacity; j++) {
        if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET) continue;

        struct socket_fdinfo sinfo;
        memset(&sinfo, 0, sizeof(sinfo));
        int sgot = proc_pidfdinfo(pid, fds[j].proc_fd,
                                  PROC_PIDFDSOCKETINFO,
                                  &sinfo, PROC_PIDFDSOCKETINFO_SIZE);
        if (sgot != (int)PROC_PIDFDSOCKETINFO_SIZE) continue;

        if (sinfo.psi.soi_kind != SOCKINFO_TCP) continue;
        if (sinfo.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_ESTABLISHED) continue;

        const struct in_sockinfo *ini = &sinfo.psi.soi_proto.pri_tcp.tcpsi_ini;

        WaikConnection c;
        memset(&c, 0, sizeof(c));
        c.pid = (int32_t)pid;
        strncpy(c.process_name, comm, WAIK_NAME_MAX - 1);

        c.remote_port = ntohs((uint16_t)ini->insi_fport);

        if (ini->insi_vflag & INI_IPV4) {
            const struct in_addr *a = &ini->insi_faddr.ina_46.i46a_addr4;
            if (!inet_ntop(AF_INET, a, c.remote_address, WAIK_ADDR_MAX)) continue;
        } else if (ini->insi_vflag & INI_IPV6) {
            const struct in6_addr *a = &ini->insi_faddr.ina_6;
            if (!inet_ntop(AF_INET6, a, c.remote_address, WAIK_ADDR_MAX)) continue;
        } else {
            continue;
        }

        c.bytes_in_buffer = sinfo.psi.soi_rcv.sbi_cc + sinfo.psi.soi_snd.sbi_cc;

        out[cursor++] = c;
        written++;
    }

    free(fds);
    return written;
}

ptrdiff_t waik_scan_connections(WaikConnection *out, size_t out_capacity) {
    if (out == NULL || out_capacity == 0) return 0;

    size_t pid_count = 0;
    int *pids = waik_list_pids(&pid_count);
    if (!pids || pid_count == 0) {
        if (pids) free(pids);
        return 0;
    }

    size_t written = 0;
    for (size_t i = 0; i < pid_count && written < out_capacity; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;

        char comm[WAIK_NAME_MAX];
        if (!waik_resolve_comm(pid, comm, sizeof(comm))) continue;

        written += waik_scan_pid(pid, comm, out, written, out_capacity);
    }

    free(pids);
    return (ptrdiff_t)written;
}

uint64_t waik_pid_cpu_ns(int32_t pid) {
    if (pid <= 0) return 0;
    struct proc_taskinfo ti;
    memset(&ti, 0, sizeof(ti));
    int got = proc_pidinfo((pid_t)pid, PROC_PIDTASKINFO, 0,
                           &ti, PROC_PIDTASKINFO_SIZE);
    if (got != (int)PROC_PIDTASKINFO_SIZE) return 0;
    return ti.pti_total_user + ti.pti_total_system;
}
