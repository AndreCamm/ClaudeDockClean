// Stands in for chrome-headless-shell. The real binary is the same
// path with ".real" appended. Headless shell is not a hardened runtime,
// so the inserted library loads in the browser and in the helpers it
// relaunches.

#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef CHS_GUARD_LIB
#define CHS_GUARD_LIB "/Users/andre/.local/lib/libchsguard.dylib"
#endif

int main(int argc, char **argv) {
    char self[4096];
    uint32_t size = sizeof self;
    if (_NSGetExecutablePath(self, &size) != 0) return 127;

    char real[4120];
    int n = snprintf(real, sizeof real, "%s.real", self);
    if (n < 0 || n >= (int)sizeof real) return 127;

    const char *existing = getenv("DYLD_INSERT_LIBRARIES");
    if (existing && existing[0]) {
        char joined[8192];
        snprintf(joined, sizeof joined, "%s:%s", CHS_GUARD_LIB, existing);
        setenv("DYLD_INSERT_LIBRARIES", joined, 1);
    } else {
        setenv("DYLD_INSERT_LIBRARIES", CHS_GUARD_LIB, 1);
    }

    execv(real, argv);
    perror("chrome-headless-shell");
    return 127;
}
