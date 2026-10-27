// Build wrapper for the vendored sqlite-vec amalgamation. SQLITE_CORE makes it call the system
// SQLite directly rather than through the loadable-extension API table, so it can be linked statically.
#include <stddef.h>
#include "CSQLiteVec.h"
#include "sqlite-vec.h"

int csqlitevec_register(sqlite3 *db, char **error) {
    return sqlite3_vec_init(db, error, NULL);
}

const char *csqlitevec_version(void) {
    return SQLITE_VEC_VERSION;
}
