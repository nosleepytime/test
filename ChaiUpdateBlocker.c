/*
 * ChaiUpdateBlocker — minimal iOS arm64 runtime tweak.
 * Attempts to suppress only Chai's specific native update UIAlertController.
 * It does not bypass any server-side version enforcement.
 */

typedef void *Obj;
typedef void *Cls;
typedef void *Sel;
typedef void *Method;
typedef void *Imp;
typedef signed char Bool;

extern Cls objc_getClass(const char *);
extern Sel sel_registerName(const char *);
extern Method class_getInstanceMethod(Cls, Sel);
extern Imp method_setImplementation(Method, Imp);
extern Obj objc_msgSend(Obj, Sel, ...);

static void (*original_present)(Obj, Sel, Obj, Bool, Obj) = 0;

static char lowercase_ascii(char ch) {
    return (ch >= 'A' && ch <= 'Z') ? (char)(ch + ('a' - 'A')) : ch;
}

static int contains_case_insensitive(const char *haystack, const char *needle) {
    if (!haystack || !needle || !needle[0]) return 0;
    for (const char *h = haystack; *h; h++) {
        const char *a = h, *b = needle;
        while (*a && *b && lowercase_ascii(*a) == lowercase_ascii(*b)) {
            a++;
            b++;
        }
        if (!*b) return 1;
    }
    return 0;
}

static const char *nsstring_utf8(Obj string) {
    if (!string) return 0;
    return ((const char *(*)(Obj, Sel))objc_msgSend)(
        string, sel_registerName("UTF8String"));
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type-mismatch"

static int is_chai_update_alert(Obj controller) {
    Cls alert_class = objc_getClass("UIAlertController");
    if (!controller || !alert_class) return 0;

    Bool is_alert = ((Bool (*)(Obj, Sel, Cls))objc_msgSend)(
        controller, sel_registerName("isKindOfClass:"), alert_class);
    if (!is_alert) return 0;

    Obj title_string = ((Obj (*)(Obj, Sel))objc_msgSend)(
        controller, sel_registerName("title"));
    Obj message_string = ((Obj (*)(Obj, Sel))objc_msgSend)(
        controller, sel_registerName("message"));
    const char *title = nsstring_utf8(title_string);
    const char *message = nsstring_utf8(message_string);

    if (contains_case_insensitive(title, "get you up to date")) return 1;
    if (contains_case_insensitive(message, "best experience on Chai") &&
        contains_case_insensitive(message, "latest version")) return 1;
    return 0;
}

static void filtered_present(Obj presenter, Sel selector, Obj controller,
                             Bool animated, Obj completion) {
    if (is_chai_update_alert(controller)) {
        return;
    }
    if (original_present) {
        original_present(presenter, selector, controller, animated, completion);
    }
}

#pragma clang diagnostic pop

__attribute__((constructor))
static void install_chai_update_filter(void) {
    Cls view_controller = objc_getClass("UIViewController");
    if (!view_controller) return;

    Method present = class_getInstanceMethod(
        view_controller,
        sel_registerName("presentViewController:animated:completion:"));
    if (!present) return;

    original_present = (void (*)(Obj, Sel, Obj, Bool, Obj))
        method_setImplementation(present, (Imp)filtered_present);
}
