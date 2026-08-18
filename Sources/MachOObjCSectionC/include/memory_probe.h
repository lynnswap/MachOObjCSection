//
//  memory_probe.h
//  MachOObjCSectionC
//
//  Probe whether a virtual address range is mapped and readable in the
//  current task. Used by the Swift side to guard `.pointee` loads against
//  stale `class_rw_t` / `class_rw_ext_t` pointers that appear when a
//  foreign-platform binary (e.g. an iOS simulator framework) is loaded
//  standalone on a macOS host: the runtime stores preopt offsets into the
//  iOS dyld shared cache that, with the cache unmapped, resolve to
//  unmapped low addresses and segfault on dereference.
//

#ifndef memory_probe_h
#define memory_probe_h

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns `true` iff `length` bytes starting at `address` are mapped and
/// readable in the current task. Uses `mach_vm_read_overwrite` to probe every
/// page touched by the range before the Swift side dereferences it.
bool MachOObjCSectionIsMemoryReadable(const void *address, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* memory_probe_h */
