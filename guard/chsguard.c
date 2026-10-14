// Loaded into chrome-headless-shell through the chs-wrap stand-in.
//
// The shell has no app bundle. When a Dock app such as T3 Code launches it,
// Launch Services files every chrome process that checks in under the
// parent's identity. The browser process checks in as a UI element. Its
// audio and video capture helpers check in as well. On macOS 27 the Dock
// inserts a tile as soon as a second process registers under the parent,
// whatever type that process declares, and about half of those tiles are
// never removed. That is the row of "T3 Code (Nightly)" icons.
//
// The fix is to keep the helper processes out of Launch Services entirely.
// A process with no record cannot get a tile. Camera, microphone and audio
// output inside the browser do not depend on the registration; they were
// tested with getUserMedia and AudioContext before and after this change.
// GPU, network and renderer processes never register, so this is a no-op
// for them. The browser process is left alone.

#include <crt_externs.h>
#include <stdlib.h>
#include <string.h>

typedef const void *CFTypeRef;
typedef const void *CFDictionaryRef;

typedef struct {
    unsigned int highLongOfPSN;
    unsigned int lowLongOfPSN;
} ProcessSerialNumber;

extern CFTypeRef _LSApplicationCheckIn(long session, CFDictionaryRef info);
extern int TransformProcessType(const ProcessSerialNumber *psn, unsigned int transform);

#define DYLD_INTERPOSE(replacement, replacee)                                           \
    __attribute__((used)) static struct {                                               \
        const void *replacement;                                                        \
        const void *replacee;                                                           \
    } interpose_##replacee __attribute__((section("__DATA,__interpose"))) = {           \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee};

// True for every chrome child process (anything launched with --type=).
static int is_child_process(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    cached = 0;
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--type=", 7) == 0) {
            cached = 1;
            break;
        }
    }
    return cached;
}

static CFTypeRef guarded_checkin(long session, CFDictionaryRef info) {
    if (is_child_process()) return NULL;
    return _LSApplicationCheckIn(session, info);
}
DYLD_INTERPOSE(guarded_checkin, _LSApplicationCheckIn)

// TransformProcessType registers the process as a side effect.
static int guarded_transform(const ProcessSerialNumber *psn, unsigned int transform) {
    if (is_child_process()) return 0;
    return TransformProcessType(psn, transform);
}
DYLD_INTERPOSE(guarded_transform, TransformProcessType)
