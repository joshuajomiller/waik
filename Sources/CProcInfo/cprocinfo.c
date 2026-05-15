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

ptrdiff_t waik_scan_connections(WaikConnection *out, size_t out_capacity) {
    if (out == NULL || out_capacity == 0) return 0;

    int pid_bytes = proc_listallpids(NULL, 0);
    if (pid_bytes <= 0) return 0;

    int *pids = (int *)malloc((size_t)pid_bytes);
    if (!pids) return -1;

    int got = proc_listallpids(pids, pid_bytes);
    if (got <= 0) { free(pids); return 0; }
    size_t pid_count = (size_t)got / sizeof(int);

    size_t written = 0;
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];

    for (size_t i = 0; i < pid_count && written < out_capacity; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;

        memset(pathbuf, 0, sizeof(pathbuf));
        int pn = proc_pidpath(pid, pathbuf, sizeof(pathbuf));
        if (pn <= 0) continue;

        // basename can modify its argument on some platforms; copy first.
        char pathcopy[PROC_PIDPATHINFO_MAXSIZE];
        memcpy(pathcopy, pathbuf, sizeof(pathbuf));
        char *bname = basename(pathcopy);
        if (!bname || !*bname) continue;

        int fd_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (fd_bytes <= 0) continue;

        struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)fd_bytes);
        if (!fds) continue;

        int actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, fd_bytes);
        if (actual <= 0) { free(fds); continue; }
        size_t fd_count = (size_t)actual / sizeof(struct proc_fdinfo);

        for (size_t j = 0; j < fd_count && written < out_capacity; j++) {
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
            strncpy(c.process_name, bname, WAIK_NAME_MAX - 1);

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

            out[written++] = c;
        }

        free(fds);
    }

    free(pids);
    return (ptrdiff_t)written;
}
