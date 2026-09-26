#include "memory_probe.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    size_t page = (size_t)getpagesize();
    unsigned char *bytes = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(bytes != MAP_FAILED);
    memset(bytes, 0x42, page);
    assert(mprotect(bytes + page, page, PROT_NONE) == 0);
    uint64_t result = 0;
    assert(MachOObjCSectionCopyMemory(bytes, &result, sizeof(result)));
    assert(result == UINT64_C(0x4242424242424242));
    assert(MachOObjCSectionIsMemoryReadable(bytes, page));
    assert(!MachOObjCSectionCopyMemory(bytes + page - 4, &result, sizeof(result)));
    assert(!MachOObjCSectionIsMemoryReadable(bytes + page - 4, 8));
    assert(!MachOObjCSectionCopyMemory((const void *)1, &result, sizeof(result)));
    assert(!MachOObjCSectionIsMemoryReadable((const void *)1, 1));
    assert(munmap(bytes, page * 2) == 0);
    return 0;
}
