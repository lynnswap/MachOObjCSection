//
//  memory_probe.c
//  MachOObjCSectionC
//

#include "memory_probe.h"

#include <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/mach_types.h>
#include <mach/vm_types.h>
#include <stdint.h>
#include <unistd.h>

// `<mach/mach_vm.h>` is publicly marked `unsupported` on the iOS SDK, but
// `mach_vm_read_overwrite` itself is exported by libsystem_kernel on every
// Apple platform. Forward-declare it so we can use the 64-bit-clean variant
// without pulling in the unsupported header.
extern kern_return_t mach_vm_read_overwrite(
    vm_map_read_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    mach_vm_address_t data,
    mach_vm_size_t *outsize
);

static bool probe_byte(mach_vm_address_t address) {
    uint8_t scratch = 0;
    mach_vm_size_t outSize = 0;
    kern_return_t result = mach_vm_read_overwrite(
        mach_task_self(),
        address,
        1,
        (mach_vm_address_t)(uintptr_t)&scratch,
        &outSize
    );
    return result == KERN_SUCCESS && outSize == 1;
}

bool MachOObjCSectionIsMemoryReadable(const void *address, size_t length) {
    if (address == NULL || length == 0) {
        return false;
    }

    mach_vm_address_t startAddress = (mach_vm_address_t)(uintptr_t)address;
    if (!probe_byte(startAddress)) {
        return false;
    }

    if (length <= 1) {
        return true;
    }

    mach_vm_size_t trailingLength = (mach_vm_size_t)(length - 1);
    if (trailingLength > UINT64_MAX - startAddress) {
        return false;
    }
    mach_vm_address_t endAddress = startAddress + trailingLength;
    mach_vm_address_t pageSize = (mach_vm_address_t)getpagesize();
    mach_vm_address_t startPage = startAddress / pageSize;
    mach_vm_address_t endPage = endAddress / pageSize;
    if (startPage == endPage) {
        return true;
    }

    for (mach_vm_address_t page = startPage + 1; page < endPage; page++) {
        if (!probe_byte(page * pageSize)) {
            return false;
        }
    }
    return probe_byte(endAddress);
}
