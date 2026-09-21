/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <windows.h>
#include <stdio.h>
typedef LONG (WINAPI *lookup_fn)(HANDLE, void **);
typedef LONG (WINAPI *exit_fn)(void *);
typedef void (WINAPI *release_fn)(void *);
int main(void)
{
    HMODULE kernel = LoadLibraryA("ntoskrnl.exe");
    lookup_fn lookup = (lookup_fn)(void *)GetProcAddress(kernel, "PsLookupProcessByProcessId");
    exit_fn query = (exit_fn)(void *)GetProcAddress(kernel, "PsGetProcessExitStatus");
    release_fn release = (release_fn)(void *)GetProcAddress(kernel, "ObfDereferenceObject");
    STARTUPINFOA si = { .cb = sizeof(si) };
    PROCESS_INFORMATION pi;
    char path[32768];
    void *object;
    LONG running, exited;
    if (!lookup || !query || !release) return 1;
    GetModuleFileNameA(NULL, path, sizeof(path));
    if (!CreateProcessA(path, NULL, NULL, NULL, FALSE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)) return 2;
    if (lookup((HANDLE)(ULONG_PTR)pi.dwProcessId, &object)) { TerminateProcess(pi.hProcess, 1); return 3; }
    running = query(object);
    TerminateProcess(pi.hProcess, 0x12345);
    WaitForSingleObject(pi.hProcess, 5000);
    exited = query(object);
    release(object);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    printf("running=%08lx exited=%08lx\n", running, exited);
    return running != 0x103 || exited != 0x12345;
}
