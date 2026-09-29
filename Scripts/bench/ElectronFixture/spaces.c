// Node-API addon for the disposable Electron fixture: moves this process's own window
// between desktops with the same private SkyLight calls the AppKit fixtures use
// (Scripts/bench/InputFixture). WindowServer only honours these calls for windows the
// calling connection owns, so the harness cannot do this from outside the app.
//
// The few Node-API declarations are written out (the ABI is stable), so building needs
// only clang: see Scripts/bench/build-electron-fixture.sh. Test-only; never shipped.
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct napi_env__ *napi_env;
typedef struct napi_value__ *napi_value;
typedef struct napi_callback_info__ *napi_callback_info;
typedef int napi_status;
typedef napi_value (*napi_callback)(napi_env, napi_callback_info);

extern napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t *, napi_value *, napi_value *, void **);
extern napi_status napi_get_value_int64(napi_env, napi_value, int64_t *);
extern napi_status napi_create_int64(napi_env, int64_t, napi_value *);
extern napi_status napi_create_array_with_length(napi_env, size_t, napi_value *);
extern napi_status napi_set_element(napi_env, napi_value, uint32_t, napi_value);
extern napi_status napi_create_function(napi_env, const char *, size_t, napi_callback, void *, napi_value *);
extern napi_status napi_set_named_property(napi_env, napi_value, const char *, napi_value);
extern napi_status napi_get_undefined(napi_env, napi_value *);

typedef int32_t (*MainConnection)(void);
typedef void (*MoveToSpace)(int32_t, CFArrayRef, uint64_t);
typedef CFArrayRef (*CopySpaces)(int32_t, int32_t, CFArrayRef);
typedef CFArrayRef (*CopyDisplaySpaces)(int32_t);

static void *symbol(const char *name) { return dlsym(RTLD_DEFAULT, name); }

static CFArrayRef windowList(int64_t window) {
    int32_t value = (int32_t)window;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &value);
    CFArrayRef list = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    return list;
}

/// Spaces of one window; returns the count written to `out`.
static size_t spacesOf(int64_t window, uint64_t *out, size_t capacity) {
    MainConnection main = symbol("CGSMainConnectionID");
    CopySpaces copy = symbol("CGSCopySpacesForWindows");
    if (!main || !copy) return 0;
    CFArrayRef list = windowList(window);
    CFArrayRef spaces = copy(main(), 0x7, list);
    CFRelease(list);
    if (!spaces) return 0;
    size_t count = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(spaces) && count < capacity; i++) {
        uint64_t id = 0;
        if (CFNumberGetValue(CFArrayGetValueAtIndex(spaces, i), kCFNumberSInt64Type, &id)) out[count++] = id;
    }
    CFRelease(spaces);
    return count;
}

static int64_t argument(napi_env env, napi_callback_info info, size_t index) {
    size_t count = 2;
    napi_value values[2];
    int64_t result = 0;
    if (napi_get_cb_info(env, info, &count, values, NULL, NULL) != 0 || index >= count) return 0;
    napi_get_value_int64(env, values[index], &result);
    return result;
}

static napi_value js_spacesOf(napi_env env, napi_callback_info info) {
    uint64_t found[16];
    size_t count = spacesOf(argument(env, info, 0), found, 16);
    napi_value array;
    napi_create_array_with_length(env, count, &array);
    for (size_t i = 0; i < count; i++) {
        napi_value number;
        napi_create_int64(env, (int64_t)found[i], &number);
        napi_set_element(env, array, (uint32_t)i, number);
    }
    return array;
}

/// Another ordinary desktop on the display that holds the window, or 0.
static napi_value js_otherDesktop(napi_env env, napi_callback_info info) {
    int64_t window = argument(env, info, 0);
    uint64_t current[16];
    size_t currentCount = spacesOf(window, current, 16);
    int64_t target = 0;
    MainConnection main = symbol("CGSMainConnectionID");
    CopyDisplaySpaces copy = symbol("CGSCopyManagedDisplaySpaces");
    CFArrayRef displays = (main && copy) ? copy(main()) : NULL;
    for (CFIndex d = 0; displays && d < CFArrayGetCount(displays) && !target; d++) {
        CFDictionaryRef display = CFArrayGetValueAtIndex(displays, d);
        CFArrayRef spaces = CFDictionaryGetValue(display, CFSTR("Spaces"));
        if (!spaces) continue;
        bool holdsWindow = false;
        uint64_t candidate = 0;
        for (CFIndex s = 0; s < CFArrayGetCount(spaces); s++) {
            CFDictionaryRef space = CFArrayGetValueAtIndex(spaces, s);
            int type = -1;
            uint64_t id = 0;
            CFNumberRef typeValue = CFDictionaryGetValue(space, CFSTR("type"));
            CFNumberRef idValue = CFDictionaryGetValue(space, CFSTR("id64"));
            if (!typeValue || !idValue) continue;
            CFNumberGetValue(typeValue, kCFNumberIntType, &type);
            CFNumberGetValue(idValue, kCFNumberSInt64Type, &id);
            if (type != 0) continue; // ordinary desktops only, never full-screen spaces
            bool isCurrent = false;
            for (size_t i = 0; i < currentCount; i++) if (current[i] == id) isCurrent = true;
            if (isCurrent) holdsWindow = true;
            else if (!candidate) candidate = id;
        }
        if (holdsWindow && candidate) target = (int64_t)candidate;
    }
    if (displays) CFRelease(displays);
    napi_value result;
    napi_create_int64(env, target, &result);
    return result;
}

static napi_value js_moveToSpace(napi_env env, napi_callback_info info) {
    MainConnection main = symbol("CGSMainConnectionID");
    MoveToSpace move = symbol("CGSMoveWindowsToManagedSpace");
    int64_t window = argument(env, info, 0), space = argument(env, info, 1);
    if (main && move && window > 0 && space > 0) {
        CFArrayRef list = windowList(window);
        move(main(), list, (uint64_t)space);
        CFRelease(list);
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

__attribute__((visibility("default")))
int32_t node_api_module_get_api_version_v1(void) { return 8; }

__attribute__((visibility("default")))
napi_value napi_register_module_v1(napi_env env, napi_value exports) {
    const struct { const char *name; napi_callback callback; } functions[] = {
        {"spacesOf", js_spacesOf}, {"otherDesktop", js_otherDesktop}, {"moveToSpace", js_moveToSpace}};
    for (size_t i = 0; i < sizeof functions / sizeof functions[0]; i++) {
        napi_value function;
        if (napi_create_function(env, functions[i].name, (size_t)-1, functions[i].callback, NULL, &function) == 0) {
            napi_set_named_property(env, exports, functions[i].name, function);
        }
    }
    return exports;
}
