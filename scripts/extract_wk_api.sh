#!/usr/bin/env sh
# extract_wk_api.sh — print the verbatim declarations this backend depends on.
#
#   WK_SRC=/c/projects/WebKit sh scripts/extract_wk_api.sh
#
# Purpose: the binding in engine/webkit.v + engine/wk_host.h is only correct if
# its signatures match the headers of the WebKit revision you actually built.
# This prints them side by side with their source file so a diff against a newer
# upstream revision takes two minutes instead of a debugging session.
set -eu

WK_SRC="${WK_SRC:-}"
[ -n "$WK_SRC" ] || { echo "set WK_SRC=<webkit checkout>" >&2; exit 1; }

S="$WK_SRC/Source/WebKit"

show() { # show <file> <regex>
	f="$1"; pat="$2"
	echo
	echo "--- $f"
	grep -nE "WK_EXPORT.*($pat)" "$f" || echo "    (no match)"
}

echo "### WinCairo embedding API (UIProcess/API/C/win)"
show "$S/UIProcess/API/C/win/WKView.h" 'WKView[A-Za-z]*'

echo
echo "### Page"
show "$S/UIProcess/API/C/WKPage.h" 'WKPage(LoadURL|LoadHTMLString|EvaluateJavaScriptInMainFrame|CopyTitle|CopyActiveURL|GetInspector|Close|Terminate)[A-Za-z]*'

echo
echo "### Configuration"
show "$S/UIProcess/API/C/WKPageConfigurationRef.h" 'WKPageConfiguration(Create|SetUserContentController|SetContext|GetPreferences)[A-Za-z]*'

echo
echo "### Bridge (JS -> V)"
show "$S/UIProcess/API/C/WKUserContentControllerRef.h" 'WKUserContentController(Create|AddUserScript|AddScriptMessageHandler)[A-Za-z]*'
show "$S/UIProcess/API/C/WKUserScriptRef.h" 'WKUserScriptCreateWithSource'
show "$S/UIProcess/API/C/WKScriptMessageRef.h" 'WKScriptMessageGet[A-Za-z]*'
echo
echo "--- the ScriptMessageHandler callback typedef + injection-time enum"
grep -nE 'typedef void \(\*WKScriptMessageHandlerCallback\)' "$S/UIProcess/API/C/WKUserContentControllerRef.h" || true
grep -nE '_WKUserScriptInjectionTime' "$S/UIProcess/API/C/WKUserScriptInjectionTime.h" || true

echo
echo "### Inspector"
show "$S/UIProcess/API/C/WKInspector.h" 'WKInspector(GetPage|Connect|Show|Hide|Attach|Detach|IsVisible)[A-Za-z]*'

echo
echo "### Strings / URLs / refcounting (Shared/API/c)"
show "$S/Shared/API/c/WKString.h" 'WKString(CreateWithUTF8CString|GetUTF8CString|GetMaximumUTF8CStringSize|GetTypeID)[A-Za-z]*'
show "$S/Shared/API/c/WKURL.h" 'WKURL(CreateWithUTF8CString|CopyString)[A-Za-z]*'
show "$S/Shared/API/c/WKBase.h" 'WKTypeGetTypeID|WKRelease|WKRetain'

echo
echo "### Preferences (dev_mode -> developer extras)"
grep -nE 'WKPreferencesSetDeveloperExtrasEnabled' "$S/UIProcess/API/C/WKPreferencesRef.h" || \
	echo "    (check the name in WKPreferencesRef.h: it may be deprecated)"

echo
echo "Reminder: also copy any header added here into scripts/stage_runtime.sh's dir list."
