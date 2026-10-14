// Loaded into agent CLIs (Claude Code, Codex) so a subagent cannot
// register as a second Dock icon of the app that launched it.
//
// macOS attributes a child with no bundle of its own to the responsible
// GUI parent. If that child then starts NSApplication as a regular app,
// Launch Services adds another Foreground tile under the parent's name.
// Accessory processes do not get a Dock tile. Screen recording and
// accessibility stay with the parent, because this does not disclaim
// the agent process itself.

#import <objc/runtime.h>
#import <dlfcn.h>
#import <spawn.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

extern void NSApplicationMain(int argc, char **argv);
__attribute__((used)) static void *dg_keep_appkit = (void *)&NSApplicationMain;

static IMP orig_setPolicy = NULL;
static IMP orig_finish = NULL;
static IMP orig_init = NULL;
static int installed = 0;
static int noted = 0;

static void note_once(void) {
    if (noted) return;
    noted = 1;
    const char *home = getenv("HOME");
    if (!home) return;
    char path[1024];
    int n = snprintf(path, sizeof path, "%s/Library/Logs/dockguard.log", home);
    if (n < 0 || n >= (int)sizeof path) return;
    FILE *f = fopen(path, "a");
    if (!f) return;
    fprintf(f, "pid %d kept accessory: %s\n", getpid(), getprogname());
    fclose(f);
}

static BOOL swz_setPolicy(id self, SEL _cmd, long policy) {
    if (policy == 0) {
        policy = 1;
        note_once();
    }
    return ((BOOL (*)(id, SEL, long))orig_setPolicy)(self, _cmd, policy);
}

static void swz_finish(id self, SEL _cmd) {
    if (orig_setPolicy) {
        ((BOOL (*)(id, SEL, long))orig_setPolicy)(self, @selector(setActivationPolicy:), 1);
        note_once();
    }
    ((void (*)(id, SEL))orig_finish)(self, _cmd);
}

static id swz_init(id self, SEL _cmd) {
    id obj = ((id (*)(id, SEL))orig_init)(self, _cmd);
    if (obj && orig_setPolicy) {
        ((BOOL (*)(id, SEL, long))orig_setPolicy)(obj, @selector(setActivationPolicy:), 1);
    }
    return obj;
}

static void install(void) {
    if (installed) return;
    Class cls = objc_getClass("NSApplication");
    if (!cls) return;
    Method setp = class_getInstanceMethod(cls, @selector(setActivationPolicy:));
    Method finish = class_getInstanceMethod(cls, @selector(finishLaunching));
    Method initm = class_getInstanceMethod(cls, @selector(init));
    if (!setp || !finish || !initm) return;
    orig_setPolicy = method_setImplementation(setp, (IMP)swz_setPolicy);
    orig_finish = method_setImplementation(finish, (IMP)swz_finish);
    orig_init = method_setImplementation(initm, (IMP)swz_init);
    installed = 1;
}

// Browsers spawned by an agent still inherit the parent app's Dock
// identity. Disclaim only those, so the agent itself keeps the parent's
// screen-recording and accessibility grants.
static int (*real_posix_spawn)(
    pid_t *pid,
    const char *path,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *attrp,
    char *const argv[],
    char *const envp[]
) = NULL;

static int (*real_posix_spawnp)(
    pid_t *pid,
    const char *file,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *attrp,
    char *const argv[],
    char *const envp[]
) = NULL;

static int (*set_disclaim)(posix_spawnattr_t *attrs, int disclaim) = NULL;

static int is_browser(const char *path) {
    if (!path) return 0;
    return strstr(path, "chrome-headless-shell")
        || strstr(path, "ms-playwright")
        || strstr(path, "Chromium.app")
        || strstr(path, "Google Chrome for Testing")
        || strstr(path, "Google Chrome.app");
}

static const posix_spawnattr_t *claim_attr(const posix_spawnattr_t *attrp, posix_spawnattr_t *local, int *own) {
    *own = 0;
    if (!set_disclaim || !attrp) {
        if (!set_disclaim) return attrp;
        if (posix_spawnattr_init(local) != 0) return attrp;
        *own = 1;
        set_disclaim(local, 1);
        return local;
    }
    set_disclaim((posix_spawnattr_t *)attrp, 1);
    return attrp;
}

static int my_posix_spawn(
    pid_t *pid,
    const char *path,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *attrp,
    char *const argv[],
    char *const envp[]
) {
    if (!real_posix_spawn) {
        real_posix_spawn = dlsym(RTLD_NEXT, "posix_spawn");
    }
    if (!real_posix_spawn) return -1;
    if (!is_browser(path)) {
        return real_posix_spawn(pid, path, file_actions, attrp, argv, envp);
    }
    posix_spawnattr_t local;
    int own = 0;
    const posix_spawnattr_t *use = claim_attr(attrp, &local, &own);
    int rc = real_posix_spawn(pid, path, file_actions, use, argv, envp);
    if (own) posix_spawnattr_destroy(&local);
    return rc;
}

static int my_posix_spawnp(
    pid_t *pid,
    const char *file,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *attrp,
    char *const argv[],
    char *const envp[]
) {
    if (!real_posix_spawnp) {
        real_posix_spawnp = dlsym(RTLD_NEXT, "posix_spawnp");
    }
    if (!real_posix_spawnp) return -1;
    if (!is_browser(file)) {
        return real_posix_spawnp(pid, file, file_actions, attrp, argv, envp);
    }
    posix_spawnattr_t local;
    int own = 0;
    const posix_spawnattr_t *use = claim_attr(attrp, &local, &own);
    int rc = real_posix_spawnp(pid, file, file_actions, use, argv, envp);
    if (own) posix_spawnattr_destroy(&local);
    return rc;
}

#define DYLD_INTERPOSE(_repl, _orig) \
    __attribute__((used)) static struct { const void *repl; const void *orig; } \
    _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_repl, (const void *)(unsigned long)&_orig }

DYLD_INTERPOSE(my_posix_spawn, posix_spawn);
DYLD_INTERPOSE(my_posix_spawnp, posix_spawnp);

__attribute__((constructor))
static void dg_ctor(void) {
    real_posix_spawn = dlsym(RTLD_NEXT, "posix_spawn");
    real_posix_spawnp = dlsym(RTLD_NEXT, "posix_spawnp");
    set_disclaim = dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    install();
}
