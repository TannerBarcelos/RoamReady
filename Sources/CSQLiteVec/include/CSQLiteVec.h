#ifndef CSQLITEVEC_H
#define CSQLITEVEC_H

#include <sqlite3.h>

/// Registers the `vec0` virtual table and `vec_*` functions on one connection. Returns an SQLite result code.
int csqlitevec_register(sqlite3 *db, char **error);

/// The vendored sqlite-vec version string, such as "v0.1.9".
const char *csqlitevec_version(void);

#endif
