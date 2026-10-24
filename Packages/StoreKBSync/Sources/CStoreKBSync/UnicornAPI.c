#include "CStoreKBSync.h"
#include <unicorn/unicorn.h>

const uintptr_t *StoreKBSyncUnicornAPI(void) {
    static const uintptr_t functions[] = {
        (uintptr_t)uc_version, (uintptr_t)uc_open, (uintptr_t)uc_close,
        (uintptr_t)uc_query, (uintptr_t)uc_ctl, (uintptr_t)uc_strerror,
        (uintptr_t)uc_mem_map, (uintptr_t)uc_mem_unmap, (uintptr_t)uc_mem_read,
        (uintptr_t)uc_mem_write, (uintptr_t)uc_reg_read, (uintptr_t)uc_reg_write,
        (uintptr_t)uc_emu_start, (uintptr_t)uc_emu_stop, (uintptr_t)uc_hook_add,
        (uintptr_t)uc_hook_del,
    };
    return functions;
}
