// Chained-fixups support for fishhook.
//
// fishhook upstream (Facebook) only handles the legacy LC_DYLD_INFO bind
// table. macOS 14+ binaries — including everything Xcode 15+ links against
// SwiftUI — instead carry LC_DYLD_CHAINED_FIXUPS, where each indirect
// symbol pointer is part of a per-segment "chain" of fixup entries that
// dyld walked at load time. To rebind those pointers we have to walk the
// chains ourselves, decode each entry against the chained-imports table,
// and overwrite the pointer in place.
//
// Layout reference: <mach-o/fixup-chains.h>.

#include "fishhook_chained.h"

#include <mach/mach.h>
#include <mach-o/loader.h>
#include <mach-o/fixup-chains.h>
#include <stdint.h>
#include <string.h>

#ifdef __LP64__
typedef struct mach_header_64 mh_t;
typedef struct segment_command_64 segment_t;
#define LC_SEGMENT_T LC_SEGMENT_64
#else
typedef struct mach_header mh_t;
typedef struct segment_command segment_t;
#define LC_SEGMENT_T LC_SEGMENT
#endif

static const char *_chained_import_name(const struct dyld_chained_fixups_header *h,
                                        const char *symbol_pool,
                                        uint32_t imports_format,
                                        uint32_t ordinal) {
    const uint8_t *imports_base = (const uint8_t *)h + h->imports_offset;
    switch (imports_format) {
        case DYLD_CHAINED_IMPORT: {
            const struct dyld_chained_import *imports =
                (const struct dyld_chained_import *)imports_base;
            return symbol_pool + imports[ordinal].name_offset;
        }
        case DYLD_CHAINED_IMPORT_ADDEND: {
            const struct dyld_chained_import_addend *imports =
                (const struct dyld_chained_import_addend *)imports_base;
            return symbol_pool + imports[ordinal].name_offset;
        }
        case DYLD_CHAINED_IMPORT_ADDEND64: {
            const struct dyld_chained_import_addend64 *imports =
                (const struct dyld_chained_import_addend64 *)imports_base;
            return symbol_pool + imports[ordinal].name_offset;
        }
        default:
            return NULL;
    }
}

static int _try_replace(void *page_base, size_t segment_size, void **slot,
                        void *replacement, void **replaced_out) {
    if (replaced_out && *slot != replacement) {
        *replaced_out = *slot;
    }
    kern_return_t kr = vm_protect(mach_task_self(),
                                  (vm_address_t)page_base,
                                  (vm_size_t)segment_size,
                                  0,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return -1;
    *slot = replacement;
    return 0;
}

static void _walk_chain(const struct dyld_chained_starts_in_segment *seg_info,
                        const struct dyld_chained_fixups_header *fix_header,
                        const char *symbol_pool,
                        intptr_t slide,
                        const segment_t *seg,
                        struct lks_chained_rebinding *rebs,
                        size_t reb_count) {
    uint16_t format = seg_info->pointer_format;
    // We support only the formats Apple actually uses on Apple Silicon /
    // x86_64 user-mode builds today.
    if (format != DYLD_CHAINED_PTR_64 &&
        format != DYLD_CHAINED_PTR_64_OFFSET &&
        format != DYLD_CHAINED_PTR_ARM64E &&
        format != DYLD_CHAINED_PTR_ARM64E_USERLAND &&
        format != DYLD_CHAINED_PTR_ARM64E_USERLAND24) {
        return;
    }

    void *seg_base = (void *)((uintptr_t)slide + seg->vmaddr);

    for (uint32_t pi = 0; pi < seg_info->page_count; pi++) {
        uint16_t start = seg_info->page_start[pi];
        if (start == DYLD_CHAINED_PTR_START_NONE) continue;

        uintptr_t page_addr = (uintptr_t)seg_base + (uintptr_t)pi * seg_info->page_size;
        uintptr_t chain_addr = page_addr + start;
        bool stop = false;
        while (!stop) {
            uint64_t raw = *(uint64_t *)chain_addr;
            uint64_t next = 0;
            uint32_t ordinal = 0;
            bool is_bind = false;

            if (format == DYLD_CHAINED_PTR_64 || format == DYLD_CHAINED_PTR_64_OFFSET) {
                struct dyld_chained_ptr_64_bind b;
                memcpy(&b, &raw, sizeof(b));
                is_bind = b.bind;
                next = b.next;
                ordinal = b.ordinal;
            } else {
                // ARM64E uses the same bind layout for the bind discriminator.
                struct dyld_chained_ptr_arm64e_bind b;
                memcpy(&b, &raw, sizeof(b));
                is_bind = b.bind;
                next = b.next;
                ordinal = b.ordinal;
            }

            if (is_bind) {
                const char *name = _chained_import_name(fix_header, symbol_pool,
                                                        fix_header->imports_format,
                                                        ordinal);
                if (name && name[0]) {
                    const char *plain = (name[0] == '_') ? name + 1 : name;
                    for (size_t r = 0; r < reb_count; r++) {
                        if (strcmp(plain, rebs[r].name) == 0) {
                            void **slot = (void **)chain_addr;
                            _try_replace(seg_base, (size_t)seg->vmsize, slot,
                                         rebs[r].replacement, rebs[r].replaced);
                            break;
                        }
                    }
                }
            }

            if (next == 0) break;
            // Pointer chain stride: ARM64E uses 8-byte stride; 64 / 64_OFFSET
            // also use 8-byte stride. Userland24 uses 8-byte stride too.
            chain_addr += next * 4;
            if (chain_addr - page_addr > seg_info->page_size) break; // safety
        }
    }
}

void lks_chained_rebind_image(const struct mach_header *header,
                              intptr_t slide,
                              struct lks_chained_rebinding rebs[],
                              size_t reb_count) {
    if (!header || reb_count == 0) return;

    const mh_t *mh = (const mh_t *)header;
    const struct linkedit_data_command *fixups_cmd = NULL;
    const segment_t *linkedit_seg = NULL;
    const segment_t *segments[64] = {0};
    int seg_count = 0;

    const struct load_command *lc =
        (const struct load_command *)((const uint8_t *)mh + sizeof(mh_t));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) {
            fixups_cmd = (const struct linkedit_data_command *)lc;
        } else if (lc->cmd == LC_SEGMENT_T) {
            const segment_t *seg = (const segment_t *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkedit_seg = seg;
            }
            if (seg_count < (int)(sizeof(segments)/sizeof(segments[0]))) {
                segments[seg_count++] = seg;
            }
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }

    if (!fixups_cmd || !linkedit_seg) return;

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_seg->vmaddr - linkedit_seg->fileoff;
    const struct dyld_chained_fixups_header *fix_header =
        (const struct dyld_chained_fixups_header *)(linkedit_base + fixups_cmd->dataoff);
    const struct dyld_chained_starts_in_image *starts_in_image =
        (const struct dyld_chained_starts_in_image *)((const uint8_t *)fix_header + fix_header->starts_offset);
    const char *symbol_pool = (const char *)fix_header + fix_header->symbols_offset;

    if (starts_in_image->seg_count > (uint32_t)seg_count) return; // safety

    for (uint32_t s = 0; s < starts_in_image->seg_count; s++) {
        uint32_t off = starts_in_image->seg_info_offset[s];
        if (off == 0) continue;
        const struct dyld_chained_starts_in_segment *seg_info =
            (const struct dyld_chained_starts_in_segment *)((const uint8_t *)starts_in_image + off);
        _walk_chain(seg_info, fix_header, symbol_pool, slide, segments[s],
                    rebs, reb_count);
    }
}
