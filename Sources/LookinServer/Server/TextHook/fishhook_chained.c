// Chained-fixups support for fishhook.
//
// REVISED IMPLEMENTATION: dyld walks the chained-fixups payload at load
// time and replaces each chain entry with the final resolved pointer.
// By the time our +load runs (let alone any later +installHooks call) the
// chain metadata is purely vestigial — the bytes in `__DATA_CONST __got`
// are already function pointers, not bind/next bitfields. So we cannot
// recover the symbol name by walking the chain.
//
// Strategy that actually works:
//   1. Resolve the symbol's "real" address with dlsym.
//   2. Scan the image's `__got` and `__la_symbol_ptr` sections for any
//      8-byte slot containing exactly that address.
//   3. vm_protect-write the matching slots to point at our replacement.
//
// This trades the symbol-name precision of the legacy fishhook path for
// something that survives the chained-fixups consolidation. False
// positives are theoretically possible (two unrelated symbols sharing
// an address) but extremely unlikely for the CoreText / CoreGraphics
// functions we target.

#include "fishhook_chained.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <string.h>

#ifdef __LP64__
typedef struct mach_header_64 mh_t;
typedef struct segment_command_64 segment_t;
typedef struct section_64 section_t;
#define LC_SEGMENT_T LC_SEGMENT_64
#else
typedef struct mach_header mh_t;
typedef struct segment_command segment_t;
typedef struct section section_t;
#define LC_SEGMENT_T LC_SEGMENT
#endif

/// Try to overwrite @c slot with @c replacement, lifting __DATA_CONST
/// protections as needed. Returns 1 on success, 0 if vm_protect failed.
static int _try_replace_slot(void *slot, void *replacement) {
    // vm_protect the page that contains the slot. Many implementations
    // request VM_PROT_COPY so the kernel makes a private copy on first
    // write rather than touching the shared __DATA_CONST page.
    vm_address_t page = (vm_address_t)slot & ~(vm_address_t)(0x4000 - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, 0x4000, 0,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return 0;
    *(void **)slot = replacement;
    return 1;
}

/// Scan a single section for any 8-byte aligned slot whose value equals
/// @c needle, and overwrite it with @c replacement. Records the first hit
/// in @c replaced_out (if non-NULL).
static int _scan_section(const section_t *sect, intptr_t slide,
                         void *needle, void *replacement, void **replaced_out) {
    if (!needle) return 0;
    void **base = (void **)((uintptr_t)slide + sect->addr);
    size_t count = sect->size / sizeof(void *);
    int hits = 0;
    for (size_t i = 0; i < count; i++) {
        if (base[i] == needle) {
            if (replaced_out && *replaced_out == NULL) {
                *replaced_out = needle;
            }
            if (_try_replace_slot(&base[i], replacement)) {
                hits++;
            }
        }
    }
    return hits;
}

void lks_chained_rebind_image(const struct mach_header *header,
                              intptr_t slide,
                              struct lks_chained_rebinding rebs[],
                              size_t reb_count) {
    if (!header || reb_count == 0) return;

    const mh_t *mh = (const mh_t *)header;

    // Pre-resolve every replacement target via dlsym so we have the real
    // address dyld would have written. Cache locally to avoid repeated
    // dlsym calls per image.
    void *needles[reb_count];
    for (size_t i = 0; i < reb_count; i++) {
        needles[i] = dlsym(RTLD_DEFAULT, rebs[i].name);
    }

    const struct load_command *lc =
        (const struct load_command *)((const uint8_t *)mh + sizeof(mh_t));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_T) {
            const segment_t *seg = (const segment_t *)lc;
            if (strcmp(seg->segname, SEG_DATA) == 0 ||
                strcmp(seg->segname, "__DATA_CONST") == 0 ||
                strcmp(seg->segname, "__AUTH_CONST") == 0) {
                const section_t *sect = (const section_t *)(seg + 1);
                for (uint32_t s = 0; s < seg->nsects; s++) {
                    // Only scan pointer-table sections to keep cost bounded
                    // and avoid clobbering data that happens to hold the
                    // same 8 bytes by coincidence.
                    if (strcmp(sect[s].sectname, "__got") == 0 ||
                        strcmp(sect[s].sectname, "__auth_got") == 0 ||
                        strcmp(sect[s].sectname, "__la_symbol_ptr") == 0 ||
                        strcmp(sect[s].sectname, "__nl_symbol_ptr") == 0) {
                        for (size_t r = 0; r < reb_count; r++) {
                            if (!needles[r]) continue;
                            _scan_section(&sect[s], slide, needles[r],
                                          rebs[r].replacement, rebs[r].replaced);
                        }
                    }
                }
            }
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
}
