// Minimal stand-in for the Windows SDK's `EventToken.h`, which is not part of the mingw
// sysroot that Zig compiles against. WebView2.h only needs the token type; the values are
// opaque to this project (they are produced and consumed by WebView2 itself).
#pragma once
#ifndef __eventtoken_h__
#define __eventtoken_h__

#include <stdint.h>

typedef struct EventRegistrationToken {
    int64_t value;
} EventRegistrationToken;

#endif
