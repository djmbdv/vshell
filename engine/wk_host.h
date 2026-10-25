/*
 * wk_host.h — C glue for vshell's WebKit (WinCairo) engine backend.
 *
 * Included from engine/webkit.v, so everything lands in the same translation
 * unit V generates. All handles cross the V boundary as `void*` and all strings
 * as `const char*`, which keeps the V side free of C type names (same style as
 * engine/ultralight.v).
 *
 * Why C here instead of pure V declarations:
 *   - windows.h is unavoidable. `WKViewCreate()` takes a RECT **by value** and
 *     needs a parent HWND, and the top-level window/message loop is ours.
 *     Hand-writing WNDCLASSW/MSG/WndProc structs in V is fragile; a header with
 *     `static` functions is not.
 *   - Ultralight's AppCore created the window for us (ulCreateWindow). WebKit2
 *     does not: WKView is a child HWND and the shell owns the frame.
 *
 * Header paths (/WebKit/WK*.h) come from the WinCairo install staging:
 *   docs/wk-api-signatures.md, scripts/stage_runtime.sh
 */
#ifndef VSHELL_WK_HOST_H
#define VSHELL_WK_HOST_H

#include <windows.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* Native folder picker (wk_host_pick_folder, below). Only Win32/COM, no WebKit:
 * IFileOpenDialog is the modern replacement for the SHBrowseForFolder tree and
 * is what the OS's own "Choose folder" uses. objbase.h brings CoInitializeEx /
 * CoCreateInstance / CoTaskMemFree; shobjidl.h brings IFileOpenDialog and the
 * FOS_* option flags. */
#include <objbase.h>
#include <shobjidl.h>

/* WebKit's WKBaseWin.h (pulled in by WKBase.h when _WIN32) does an unguarded
 * `typedef int pid_t;`. mingw-w64's <sys/types.h> has already typedef'd pid_t as
 * `long long`, and it arrives here through libgc -> <process.h>, so the two
 * collide:
 *   error: conflicting types for 'pid_t'; have 'int'
 *   note: previous declaration of 'pid_t' with type 'pid_t' {aka 'long long int'}
 * Instead of patching an upstream public header, rename the token only while the
 * WebKit headers are read, which turns their typedef into a harmless unused
 * alias. WKBaseWin.h includes nothing else, so the blast radius is that one
 * line; the #undef restores the real pid_t for our code and for libgc. The
 * `typedef pid_t WKProcessID;` lines in other WebKit headers sit outside this
 * window and keep the genuine pid_t, so they stay consistent with each other.
 * (This only surfaced against the real headers: the stub headers used earlier
 * had no such typedef.) */
#define pid_t WK_HOST_PID_T
#include <WebKit/WKBase.h>
#undef pid_t

#include <WebKit/WKString.h>
#include <WebKit/WKType.h>   /* WKGetTypeID, WKRetain and WKRelease live here, not in WKBase.h */
#include <WebKit/WKURL.h>
#include <WebKit/WKPage.h>
#include <WebKit/WKPageConfigurationRef.h>
#include <WebKit/WKPreferencesRef.h>
#include <WebKit/WKUserContentControllerRef.h>
#include <WebKit/WKUserScriptRef.h>
#include <WebKit/WKScriptMessageRef.h>
#include <WebKit/WKInspector.h>
#include <WebKit/WKView.h>   /* WinCairo: WKViewCreate(RECT, WKPageConfigurationRef, HWND) */

/* These signatures match what V generates for the V callbacks exactly (void* and
 * char*, not const char*): a mismatched function-pointer type only buys
 * -Wincompatible-pointer-types noise. */
typedef void (*wk_close_cb)(void* ctx);
typedef void (*wk_msg_cb)(char* text, void* ctx);
typedef void (*wk_eval_cb)(void* value, void* error, void* ctx);

/* -------------------------------------------------------------------------- */
/* host state                                                                  */
/* -------------------------------------------------------------------------- */

typedef struct {
    HWND        hwnd;            /* top-level window we own */
    HWND        child;           /* WKView's HWND */
    WKViewRef   view;
    WKPageRef   page;
    wk_close_cb on_close;
    void*       on_close_ctx;
    wk_msg_cb   on_message;
    void*       on_message_ctx;
    int         quit;
} wk_host_state;

static wk_host_state* g_wk_host = NULL;   /* one window per process, like vshell */

/* -------------------------------------------------------------------------- */
/* window                                                                      */
/* -------------------------------------------------------------------------- */

static LRESULT CALLBACK wk_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    wk_host_state* h = g_wk_host;

    switch (msg) {
    case WM_SIZE:
        /* The child WKView does not resize itself: the whole point of a
         * child-HWND model is that layout is the host's job. */
        if (h && h->child)
            MoveWindow(h->child, 0, 0, LOWORD(lp), HIWORD(lp), TRUE);
        return 0;
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        /* DestroyWindow() destroys children first and then the parent, so by the
         * time this runs the WKView's HWND is already gone. Releasing the
         * WKViewRef after that is safe: WebKit's own MiniBrowser releases
         * m_view from exactly this message (Tools/MiniBrowser/win/MainWindow.cpp).
         * Destructor order is NOT the exit-crash cause -- the page over-release
         * in engine/webkit.v's quit() was (see the note there). */
        if (h && !h->quit) {
            h->quit = 1;
            if (h->on_close)
                h->on_close(h->on_close_ctx);
        }
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

/* -------------------------------------------------------------------------- */
/* DPI                                                                         */
/* -------------------------------------------------------------------------- */

/* WebKit's WinCairo port takes its device scale factor from
 * deviceScaleFactorForWindow(), which reports the real monitor DPI (1.25 on a
 * 125% display) even when the process is DPI-unaware. An unaware process sees
 * virtualized coordinates from every other API, and that mismatch is visible:
 * the WKView HWND really is `client * scale` device pixels, while WebKit only
 * paints `client` of them, so a black band is left on the right and bottom and
 * the page lays out for a viewport 1/scale of the window.
 *
 * Measured on this machine: Screen reports 1536x960 on a 1920x1200 display at
 * 125%, and the gap was exactly 1/1.25 = 0.8.
 *
 * Declaring per-monitor-v2 awareness makes our coordinates physical so the two
 * agree. It must run before the first window exists; afterwards a "1280x800"
 * request has to be scaled by the DPI, or the window would come out physically
 * smaller than intended. */
static void wk_host_set_dpi_aware(void)
{
    static int done = 0;
    HMODULE user32;

    if (done)
        return;
    done = 1;

    user32 = GetModuleHandleA("user32.dll");
    if (user32) {
        /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is (HANDLE)-4. Resolved by
         * hand so this still compiles against an older SDK. */
        typedef BOOL (WINAPI *wk_set_ctx_fn)(void*);
        wk_set_ctx_fn set_ctx = (wk_set_ctx_fn)(void*)GetProcAddress(user32, "SetProcessDpiAwarenessContext");
        if (set_ctx && set_ctx((void*)(intptr_t)-4))
            return;
    }
    /* Vista fallback: system-wide awareness is enough to make the two agree. */
    SetProcessDPIAware();
}

/* Monitor DPI as a percentage of 96 (100 => 1.0, 125 => 1.25).
 * Call it only AFTER wk_host_set_dpi_aware(): while the process is unaware these
 * APIs report 96. GetDpiForSystem lives in user32, which V already links;
 * GetDeviceCaps would be the obvious alternative but it is in gdi32, and adding
 * a library for one call is not worth it (it failed the link with
 * "undefined reference to `__imp_GetDeviceCaps"). */
static int wk_host_dpi_percent(void)
{
    HMODULE user32 = GetModuleHandleA("user32.dll");
    int dpi = 96;

    if (user32) {
        typedef UINT (WINAPI *wk_get_dpi_fn)(void);
        wk_get_dpi_fn get_dpi = (wk_get_dpi_fn)(void*)GetProcAddress(user32, "GetDpiForSystem");
        if (get_dpi)
            dpi = (int)get_dpi();
    }
    if (dpi <= 0)
        dpi = 96;
    return (dpi * 100 + 48) / 96;
}

/* Creates the top-level window. Returns the state pointer (NULL on failure). */
static void* wk_host_create(const char* title, int width, int height, wk_close_cb on_close, void* ctx)
{
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSW wc;
    wk_host_state* h;
    wchar_t wtitle[512];
    RECT r;
    int x, y;

    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = wk_wndproc;
    wc.hInstance = inst;
    /* IDC_ARROW is MAKEINTRESOURCE(), i.e. an LPSTR unless UNICODE is defined, so
     * it has to go to the A-variant loader. The cursor handle is the same. */
    wc.hCursor = LoadCursorA(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"vshell-wk";
    if (!RegisterClassW(&wc))
        return NULL;

    h = (wk_host_state*)calloc(1, sizeof(wk_host_state));
    if (!h)
        return NULL;
    h->on_close = on_close;
    h->on_close_ctx = ctx;
    g_wk_host = h;

    wk_host_set_dpi_aware();
    {
        /* With awareness on, window coordinates are physical, so scale the
         * requested logical size to keep the window the size the caller asked
         * for in visual terms. */
        int pct = wk_host_dpi_percent();
        width = width * pct / 100;
        height = height * pct / 100;
    }

    /* Center on the primary monitor, like the Ultralight backend did. */
    r.left = 0; r.top = 0; r.right = width; r.bottom = height;
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    x = (GetSystemMetrics(SM_CXSCREEN) - (r.right - r.left)) / 2;
    y = (GetSystemMetrics(SM_CYSCREEN) - (r.bottom - r.top)) / 2;

    MultiByteToWideChar(CP_UTF8, 0, title, -1, wtitle, 512);

    h->hwnd = CreateWindowExW(0, L"vshell-wk", wtitle, WS_OVERLAPPEDWINDOW,
                              x, y, r.right - r.left, r.bottom - r.top,
                              NULL, NULL, inst, NULL);
    if (!h->hwnd)
        return NULL;

    ShowWindow(h->hwnd, SW_SHOW);
    return h;
}

static void* wk_host_hwnd(void* state) { return state ? (void*)((wk_host_state*)state)->hwnd : NULL; }

/* Creates the WKView over the host window and wires it to the page. */
static void* wk_host_attach_view(void* state, void* page_configuration, int width, int height)
{
    wk_host_state* h = (wk_host_state*)state;
    RECT rect;
    WKViewRef view;

    if (!h || !h->hwnd)
        return NULL;

    /* Size the view from the REAL client area, not from the size the caller
     * asked for. With a window frame and DPI scaling those differ, and a view
     * narrower than the client shows up as the black band: WebKit creates its
     * HWND with this rect and paints a surface of exactly this size, it never
     * stretches it. (WM_SIZE below keeps it in sync on every resize.) */
    if (!GetClientRect(h->hwnd, &rect)) {
        rect.left = 0; rect.top = 0; rect.right = width; rect.bottom = height;
    }
    /* NOTE: RECT is passed by value (see Include/WebKit/WKView.h). */
    view = WKViewCreate(rect, (WKPageConfigurationRef)page_configuration, h->hwnd);
    if (!view)
        return NULL;

    h->view = view;
    h->child = WKViewGetWindow(view);
    h->page = WKViewGetPage(view);
    return (void*)view;
}

static void* wk_host_page(void* state)   { return state ? (void*)((wk_host_state*)state)->page : NULL; }
static void* wk_host_view(void* state)   { return state ? (void*)((wk_host_state*)state)->view : NULL; }

/* Resize the embedded view (call from V if you resize the frame yourself). */
static void wk_host_resize_view(void* state, int width, int height)
{
    wk_host_state* h = (wk_host_state*)state;
    if (h && h->child)
        MoveWindow(h->child, 0, 0, width, height, TRUE);
}

/* Applies a page title to the frame's title bar.
 *
 * Widening UTF-8 -> UTF-16 happens here, where windows.h already lives, so the
 * V side keeps passing plain `const char*` like everywhere else. Call it only
 * when the text actually changed: SetWindowTextW sends WM_SETTEXT, and doing
 * that on every pump tick both burns messages and flickers the title bar. */
static void wk_host_set_title(void* state, const char* title)
{
    wk_host_state* h = (wk_host_state*)state;
    wchar_t wtext[512];

    if (!h || !h->hwnd || !title || !title[0])
        return;
    if (MultiByteToWideChar(CP_UTF8, 0, title, -1, wtext, 512) > 0)
        SetWindowTextW(h->hwnd, wtext);
}

/* Blocks until a message arrives or `ms` elapses: keeps the loop at ~0% CPU
 * while still giving V a periodic tick for the bridge pump. */
static void wk_host_wait(void* state, int ms)
{
    (void)state;
    MsgWaitForMultipleObjectsEx(0, NULL, (DWORD)ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
}

/* Drains the message queue. Returns 1 when the loop must stop (WM_QUIT). */
static int wk_host_pump_once(void* state)
{
    wk_host_state* h = (wk_host_state*)state;
    MSG msg;

    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT)
            return 1;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (h && h->quit)
        return 1;
    return 0;
}

static void wk_host_destroy(void* state)
{
    wk_host_state* h = (wk_host_state*)state;
    if (!h)
        return;
    /* WM_CLOSE/IDM_EXIT usually destroyed the window already (that is what
     * stops the loop). IsWindow() guards against calling DestroyWindow() with a
     * stale handle, which could name a recycled HWND. */
    if (h->hwnd && IsWindow(h->hwnd))
        DestroyWindow(h->hwnd);
    h->hwnd = NULL;
    g_wk_host = NULL;
    free(h);
}

/* -------------------------------------------------------------------------- */
/* folder dialog (the shell's first native API)                                */
/* -------------------------------------------------------------------------- */

/* Shows the OS "choose a folder" dialog. Returns a malloc'd UTF-8 absolute path
 * (free it with wk_host_free) or NULL when the user cancelled or anything failed.
 *
 * `parent` may be NULL: the shell asks for the folder BEFORE its window exists,
 * because the page-side bridge (the WKUserScript) has to carry the chosen path
 * from the very first document, and a user script is injected at document start.
 * A dialog with no owner still works, it is just not docked modally to a frame.
 *
 * FOS_FORCEFILESYSTEM guarantees the result has a file-system path, so
 * SIGDN_FILESYSPATH below cannot come back empty for a shell-only location. */
static char* wk_host_pick_folder(void* parent)
{
    IFileOpenDialog* dlg = NULL;
    IShellItem* item = NULL;
    PWSTR wpath = NULL;
    char* out = NULL;
    HRESULT hr;
    DWORD opts;
    int com_ok = 0;

    /* WebKit's WinCairo process may already have initialised COM (OleInitialize
     * in its own startup). A second CoInitializeEx on the same thread with a
     * different model returns RPC_E_CHANGED_MODE: that is not a failure for us,
     * the apartment exists and we simply must not uninitialise it. */
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (SUCCEEDED(hr))
        com_ok = 1;
    else if (hr != RPC_E_CHANGED_MODE)
        return NULL;

    hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IFileOpenDialog, (void**)&dlg);
    if (SUCCEEDED(hr)) {
        hr = dlg->lpVtbl->GetOptions(dlg, &opts);
        if (SUCCEEDED(hr))
            hr = dlg->lpVtbl->SetOptions(dlg,
                                         opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
        if (SUCCEEDED(hr))
            hr = dlg->lpVtbl->Show(dlg, (HWND)parent);
        if (SUCCEEDED(hr))
            hr = dlg->lpVtbl->GetResult(dlg, &item);
        if (SUCCEEDED(hr) && item) {
            hr = item->lpVtbl->GetDisplayName(item, SIGDN_FILESYSPATH, &wpath);
            if (SUCCEEDED(hr) && wpath) {
                /* Ask for the size first (with -1 the count INCLUDES the NUL),
                 * then convert into exactly that buffer. */
                int n = WideCharToMultiByte(CP_UTF8, 0, wpath, -1, NULL, 0, NULL, NULL);
                if (n > 0) {
                    out = (char*)malloc((size_t)n);
                    if (out)
                        WideCharToMultiByte(CP_UTF8, 0, wpath, -1, out, n, NULL, NULL);
                }
                CoTaskMemFree(wpath);
            }
        }
        if (item)
            item->lpVtbl->Release(item);
        dlg->lpVtbl->Release(dlg);
    }

    if (com_ok)
        CoUninitialize();
    return out;
}

/* -------------------------------------------------------------------------- */
/* page / configuration / bridge                                               */
/* -------------------------------------------------------------------------- */

static void* wk_page_configuration_create(void) { return (void*)WKPageConfigurationCreate(); }

static void wk_page_configuration_set_user_content_controller(void* config, void* ucc)
{
    WKPageConfigurationSetUserContentController((WKPageConfigurationRef)config,
                                               (WKUserContentControllerRef)ucc);
}

static void* wk_user_content_controller_create(void) { return (void*)WKUserContentControllerCreate(); }

static void wk_page_configuration_set_developer_extras(void* config, int enabled)
{
    WKPreferencesRef prefs = WKPageConfigurationGetPreferences((WKPageConfigurationRef)config);
    if (prefs)
        WKPreferencesSetDeveloperExtrasEnabled(prefs, enabled ? true : false);
}

static const char* WK_MSG_NS = "vshell";   /* window.webkit.messageHandlers.vshell */

/* Script message thunk: WebKit gives us the body as a WKTypeRef and does NOT
 * expose the handler name on the message, so the name is the one we registered
 * with and the payload is whatever the page posted. */
static void wk_message_thunk(WKScriptMessageRef message, WKCompletionListenerRef reply, const void* context)
{
    (void)reply;
    wk_host_state* h = (wk_host_state*)context;
    WKTypeRef body = WKScriptMessageGetBody(message);
    char* buf = NULL;
    size_t len;

    if (!h || !h->on_message || !body)
        return;
    /* WKGetTypeID (from WKType.h) is the generic type-id getter. There is no
     * WKTypeGetTypeID in the WebKit C API, which is what this call originally
     * assumed. */
    if (WKGetTypeID(body) != WKStringGetTypeID())
        return;

    len = WKStringGetMaximumUTF8CStringSize((WKStringRef)body);
    if (len == 0)
        return;
    buf = (char*)malloc(len + 1);
    if (!buf)
        return;
    WKStringGetUTF8CString((WKStringRef)body, buf, len);
    buf[len] = '\0';

    h->on_message(buf, h->on_message_ctx);
    free(buf);
}

static void wk_user_content_controller_add_message_handler(void* ucc, wk_msg_cb cb, void* ctx)
{
    wk_host_state* h = g_wk_host;
    if (h) {
        h->on_message = cb;
        h->on_message_ctx = ctx;
    }
    /* name = WK_MSG_NS; the callback identifies the channel by construction. */
    WKUserContentControllerAddScriptMessageHandler((WKUserContentControllerRef)ucc,
                                                   WKStringCreateWithUTF8CString(WK_MSG_NS),
                                                   wk_message_thunk, (const void*)h);
}

static void wk_user_content_controller_add_user_script(void* ucc, const char* source)
{
    /* 0 == WKUserScriptInjectionTimeAtDocumentStart (WKUserScriptInjectionTime.h).
     * Passed as a plain int on purpose: if the enum name ever changes, this keeps
     * compiling, and the position in the enum is the ABI contract. */
    WKUserScriptRef script = WKUserScriptCreateWithSource(
        WKStringCreateWithUTF8CString(source),
        0,
        true);
    WKUserContentControllerAddUserScript((WKUserContentControllerRef)ucc, script);
}

/* -------------------------------------------------------------------------- */
/* page operations                                                             */
/* -------------------------------------------------------------------------- */

static void wk_page_load_url(void* page, const char* url)
{
    WKPageLoadURL((WKPageRef)page, WKURLCreateWithUTF8CString(url));
}

static void wk_page_load_html(void* page, const char* html, const char* base_url)
{
    WKPageLoadHTMLString((WKPageRef)page,
                         WKStringCreateWithUTF8CString(html),
                         WKURLCreateWithUTF8CString(base_url));
}

/* Asynchronous by design: `cb` runs later on the UI process thread. */
static void wk_page_eval(void* page, const char* script, wk_eval_cb cb, void* ctx)
{
    WKPageEvaluateJavaScriptInMainFrame((WKPageRef)page,
                                        WKStringCreateWithUTF8CString(script),
                                        ctx,
                                        (WKPageEvaluateJavaScriptFunction)cb);
}

static char* wk_type_to_utf8(void* type)
{
    size_t len;
    char* buf;
    if (!type || WKGetTypeID((WKTypeRef)type) != WKStringGetTypeID())
        return NULL;
    len = WKStringGetMaximumUTF8CStringSize((WKStringRef)type);
    if (len == 0)
        return NULL;
    buf = (char*)malloc(len + 1);
    if (!buf)
        return NULL;
    WKStringGetUTF8CString((WKStringRef)type, buf, len);
    buf[len] = '\0';
    return buf;
}

/* Synchronous-ish helpers for title/URL polling from the run loop.
 *
 * WKPageCopyTitle / WKPageCopyActiveURL are "Copy" functions: they return a +1
 * reference that the caller owns. wk_type_to_utf8 only reads it, so without the
 * WKRelease below the WKString leaks -- and since the bridge pump calls
 * page_title() every tick, that is one leaked WebKit string per frame. */
static char* wk_page_copy_title(void* page)
{
    WKStringRef s = WKPageCopyTitle((WKPageRef)page);
    char* buf = wk_type_to_utf8((void*)s);
    if (s)
        WKRelease((WKTypeRef)s);
    return buf;
}

static char* wk_page_copy_url(void* page)
{
    /* WKPageCopyActiveURL returns a WKURLRef (+1), NOT a string. The previous
     * version assigned it straight to a WKStringRef, which (a) is an
     * incompatible-pointer-types error on GCC 14+ and (b) would have made
     * wk_type_to_utf8 skip it forever, so page_url() always returned ''. Convert
     * it with WKURLCopyString and release both references. */
    WKURLRef url = WKPageCopyActiveURL((WKPageRef)page);
    char* buf = NULL;
    if (url) {
        WKStringRef s = WKURLCopyString(url);   /* +1 */
        buf = wk_type_to_utf8((void*)s);
        if (s)
            WKRelease((WKTypeRef)s);
        WKRelease((WKTypeRef)url);
    }
    return buf;
}
static void  wk_host_free(void* p)          { free(p); }

/* Length of a C string, for V: `voidptr.vstring()` does not exist, so the V side
 * copies the bytes itself (engine/ultralight.v does the same for ULString). */
static size_t wk_cstr_len(const char* s)    { return s ? strlen(s) : (size_t)0; }

/* -------------------------------------------------------------------------- */
/* inspector                                                                   */
/* -------------------------------------------------------------------------- */

static int wk_page_show_inspector(void* page, int attached)
{
    WKInspectorRef inspector = WKPageGetInspector((WKPageRef)page);
    if (!inspector)
        return 0;
    WKInspectorConnect(inspector);
    if (attached)
        WKInspectorAttach(inspector);
    else
        WKInspectorDetach(inspector);   /* separate window */
    WKInspectorShow(inspector);
    return 1;
}

static int wk_page_inspector_is_visible(void* page)
{
    WKInspectorRef inspector = WKPageGetInspector((WKPageRef)page);
    return (inspector && WKInspectorIsVisible(inspector)) ? 1 : 0;
}

/* -------------------------------------------------------------------------- */
/* lifetime (single API for V)                                                 */
/* -------------------------------------------------------------------------- */

static void wk_release(void* ref) { if (ref) WKRelease((WKTypeRef)ref); }

#endif /* VSHELL_WK_HOST_H */
