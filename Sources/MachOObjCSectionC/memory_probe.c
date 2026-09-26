// memory_probe.c — bounded reads from this process.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif
#include "memory_probe.h"
#include <stdint.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/mach_types.h>
#include <mach/vm_types.h>

// The iOS SDK marks mach_vm.h unsupported, although this 64-bit read entry
// point is exported by libsystem_kernel on the supported Apple platforms.
extern kern_return_t mach_vm_read_overwrite(
    vm_map_read_t, mach_vm_address_t, mach_vm_size_t,
    mach_vm_address_t, mach_vm_size_t *
);
#elif defined(__linux__)
#include <sys/uio.h>
#endif

bool MachOObjCSectionCopyMemory(const void *address, void *destination, size_t length) {
    if (address == NULL || destination == NULL || length == 0) return false;
#if defined(__APPLE__)
    mach_vm_size_t copied = 0;
    kern_return_t result = mach_vm_read_overwrite(
        mach_task_self(), (mach_vm_address_t)(uintptr_t)address,
        (mach_vm_size_t)length, (mach_vm_address_t)(uintptr_t)destination, &copied
    );
    return result == KERN_SUCCESS && copied == (mach_vm_size_t)length;
#elif defined(__linux__)
    struct iovec local = { .iov_base = destination, .iov_len = length };
    struct iovec remote = { .iov_base = (void *)address, .iov_len = length };
    ssize_t copied = process_vm_readv(getpid(), &local, 1, &remote, 1, 0);
    return copied >= 0 && (size_t)copied == length;
#else
    return false;
#endif
}

static bool probe_byte(uintptr_t address) {
    uint8_t byte = 0;
    return MachOObjCSectionCopyMemory((const void *)address, &byte, 1);
}

bool MachOObjCSectionIsMemoryReadable(const void *address, size_t length) {
    if (address == NULL || length == 0) return false;
    uintptr_t start = (uintptr_t)address;
    if (length - 1 > UINTPTR_MAX - start || !probe_byte(start)) return false;
    uintptr_t end = start + length - 1;
    uintptr_t pageSize = (uintptr_t)getpagesize();
    uintptr_t startPage = start / pageSize;
    uintptr_t endPage = end / pageSize;
    for (uintptr_t page = startPage + 1; page < endPage; ++page) {
        if (!probe_byte(page * pageSize)) return false;
    }
    return startPage == endPage || probe_byte(end);
}
