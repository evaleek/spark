#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define UNICODE
#define _UNICODE

#define MAKEINTRESOURCE(i) ((LPCWSTR)((ULONG_PTR)((WORD)(i))))

#include <windef.h>
#include <processthreadsapi.h>
#include <winuser.h>
