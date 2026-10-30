// Build wrapper for the vendored sqlite-vec amalgamation. SQLITE_CORE makes it call the system
// SQLite directly rather than through the loadable-extension API table, so it can be linked statically.
#include <stddef.h>
#include "CSQLiteVec.h"
#include "sqlite-vec.h"

// Keep the upstream source unmodified. Xcode enables 64-to-32-bit conversion warnings;
// suppress only that diagnostic in the amalgamation, then restore checks for our wrapper.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#endif
#include "sqlite-vec.c"
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

int csqlitevec_register(sqlite3 *db, char **error) {
    return sqlite3_vec_init(db, error, NULL);
}

const char *csqlitevec_version(void) {
    return SQLITE_VEC_VERSION;
}
