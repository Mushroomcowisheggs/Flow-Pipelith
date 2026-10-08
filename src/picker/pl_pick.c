// pl_pick.c - native file / folder picker for Flow Pipelith.
//
// Why this file exists: typing or pasting a path by hand is the single most
// error-prone step in a node-based CLI runner (quotes, spaces, backslashes,
// unicode). A native picker removes that step entirely.
//
// Why C instead of driving an external script host: Flow Pipelith is
// cross-platform, so shelling out to PowerShell / osascript is neither portable
// nor predictable. This file talks to the OS directly and reports one of a
// small, explicit set of status codes, so the caller never has to guess whether
// a native picker is available.
//
// Usage:
//   pl_pick file   [start-dir] [filter-spec]   -> pick an existing file
//   pl_pick folder [start-dir]                 -> pick a folder
//   pl_pick probe                              -> report native availability
//
// filter-spec syntax: "Label|pattern|Label|pattern", e.g. "Flow files|*.flow|All files|*.*"
//
// Contract (mirrored in docs/RPC.md):
//   stdout  exactly one line of UTF-8 text on success: the chosen path
//   exit 0  a path was chosen and written to stdout
//   exit 1  the user cancelled (stdout is empty - this is NOT an error)
//   exit 2  the native picker is unavailable on this system
//   exit 3  invalid arguments or an internal failure
//
// The chosen path is emitted VERBATIM: no quoting, no escaping, no separator
// rewriting. Any transformation of a path would be a modification of the user's
// stated intent, so it is never performed here. If a shell needs quoting, that
// is a separate, explicitly requested presentation concern.

// `COBJMACROS` makes the MinGW headers expose the `IFileOpenDialog_*` helper
// macros; without it only the raw vtable members are declared.
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define PL_OK 0
#define PL_CANCELLED 1
#define PL_UNAVAILABLE 2
#define PL_FAILED 3

// UTF-8 -> freshly allocated wide string (caller frees). NULL on failure.
static wchar_t *widen(const char *utf8) {
    if (utf8 == NULL || utf8[0] == '\0') return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *out = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (out == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, n) <= 0) {
        free(out);
        return NULL;
    }
    return out;
}

// Write one UTF-8 line to stdout, verbatim apart from the added newline.
static int emit_utf8_line(const wchar_t *wide) {
    if (wide == NULL) return -1;
    int need = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    if (need <= 0) return -1;
    char *buf = (char *)malloc((size_t)need);
    if (buf == NULL) return -1;
    if (WideCharToMultiByte(CP_UTF8, 0, wide, -1, buf, need, NULL, NULL) <= 0) {
        free(buf);
        return -1;
    }
    fputs(buf, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    free(buf);
    return 0;
}

// COM is initialised per call; returns 1 if this call owns the uninitialise.
static int com_begin(void) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (hr == RPC_E_CHANGED_MODE) return 0; // already initialised, other model
    if (FAILED(hr)) return -1;
    return 1;
}

// Can we actually create the dialog on this system? Answer, do not guess.
static int native_available(void) {
    int owns = com_begin();
    if (owns < 0) return 0;
    IFileOpenDialog *dialog = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IFileOpenDialog, (void **)&dialog);
    if (dialog != NULL) IFileOpenDialog_Release(dialog);
    if (owns == 1) CoUninitialize();
    return SUCCEEDED(hr);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: pl_pick file|folder|probe [start-dir] [filter-spec]\n");
        return PL_FAILED;
    }

    const char *mode = argv[1];

    if (strcmp(mode, "probe") == 0) {
        int available = native_available();
        fputs(available ? "native\n" : "unavailable\n", stdout);
        fflush(stdout);
        return available ? PL_OK : PL_UNAVAILABLE;
    }

    int pick_folder = (strcmp(mode, "folder") == 0);
    if (!pick_folder && strcmp(mode, "file") != 0) {
        fprintf(stderr, "pl_pick: unknown mode '%s'\n", mode);
        return PL_FAILED;
    }

    int owns_com = com_begin();
    if (owns_com < 0) {
        return PL_UNAVAILABLE;
    }

    int status = PL_FAILED;
    IFileOpenDialog *dialog = NULL;
    IShellItem *item = NULL;
    wchar_t *filter_block = NULL;

    HRESULT hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IFileOpenDialog, (void **)&dialog);
    if (FAILED(hr) || dialog == NULL) {
        status = PL_UNAVAILABLE;
        goto done;
    }

    {
        FILEOPENDIALOGOPTIONS options = 0;
        hr = IFileOpenDialog_GetOptions(dialog, &options);
        if (FAILED(hr)) goto done;
        options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR;
        options |= pick_folder ? FOS_PICKFOLDERS : FOS_FILEMUSTEXIST;
        hr = IFileOpenDialog_SetOptions(dialog, options);
        if (FAILED(hr)) goto done;
    }

    // Optional start directory. Failure to apply it is not fatal: the dialog
    // simply opens at the OS default location.
    if (argc >= 3 && argv[2][0] != '\0') {
        wchar_t *start = widen(argv[2]);
        if (start != NULL) {
            IShellItem *folder = NULL;
            if (SUCCEEDED(SHCreateItemFromParsingName(start, NULL, &IID_IShellItem, (void **)&folder)) &&
                folder != NULL) {
                IFileOpenDialog_SetFolder(dialog, folder);
                IShellItem_Release(folder);
            }
            free(start);
        }
    }

    // Optional filter list (file mode only). The buffer must stay alive until
    // after Show(), so it is owned here and released in `done`.
    if (!pick_folder && argc >= 4 && argv[3][0] != '\0') {
        filter_block = widen(argv[3]);
        if (filter_block != NULL) {
            COMDLG_FILTERSPEC filters[8];
            UINT count = 0;
            wchar_t *cursor = filter_block;
            while (count < 8 && cursor != NULL && *cursor != L'\0') {
                wchar_t *label = cursor;
                wchar_t *bar = wcschr(label, L'|');
                if (bar == NULL) break;
                *bar = L'\0';
                wchar_t *pattern = bar + 1;
                wchar_t *next = wcschr(pattern, L'|');
                if (next != NULL) {
                    *next = L'\0';
                    cursor = next + 1;
                } else {
                    cursor = NULL;
                }
                filters[count].pszName = label;
                filters[count].pszSpec = pattern;
                count++;
            }
            if (count > 0) IFileOpenDialog_SetFileTypes(dialog, count, filters);
        }
    }

    hr = IFileOpenDialog_Show(dialog, NULL);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        status = PL_CANCELLED;
        goto done;
    }
    if (FAILED(hr)) goto done;

    hr = IFileOpenDialog_GetResult(dialog, &item);
    if (FAILED(hr) || item == NULL) goto done;

    {
        PWSTR path = NULL;
        hr = IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path);
        if (FAILED(hr) || path == NULL) goto done;
        status = (emit_utf8_line(path) == 0) ? PL_OK : PL_FAILED;
        CoTaskMemFree(path);
    }

done:
    if (filter_block != NULL) free(filter_block);
    if (item != NULL) IShellItem_Release(item);
    if (dialog != NULL) IFileOpenDialog_Release(dialog);
    if (owns_com == 1) CoUninitialize();
    return status;
}
