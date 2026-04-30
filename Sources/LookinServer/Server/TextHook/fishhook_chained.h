// Chained-fixups rebinder helper used by LKS_TextDrawHook.
// See fishhook_chained.c for design notes.

#ifndef fishhook_chained_h
#define fishhook_chained_h

#include <mach-o/loader.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct lks_chained_rebinding {
    const char *name;        /// Plain (un-leading-underscore) symbol name.
    void *replacement;
    void **replaced;         /// Optional: receives the prior pointer.
};

/// Walk the chained-fixups payload in @c header and rebind any matching
/// imports. Safe to call from a _dyld_register_func_for_add_image callback.
/// Silently returns if @c header has no LC_DYLD_CHAINED_FIXUPS load command.
void lks_chained_rebind_image(const struct mach_header *header,
                              intptr_t slide,
                              struct lks_chained_rebinding rebs[],
                              size_t reb_count);

#ifdef __cplusplus
}
#endif

#endif
