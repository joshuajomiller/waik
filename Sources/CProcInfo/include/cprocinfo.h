#ifndef CPROCINFO_H
#define CPROCINFO_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WAIK_NAME_MAX 256
#define WAIK_ADDR_MAX 64

typedef struct {
    int32_t  pid;
    char     process_name[WAIK_NAME_MAX];
    char     remote_address[WAIK_ADDR_MAX];
    uint16_t remote_port;
    uint32_t bytes_in_buffer;
} WaikConnection;

ptrdiff_t waik_scan_connections(WaikConnection *out, size_t out_capacity);

#ifdef __cplusplus
}
#endif

#endif
