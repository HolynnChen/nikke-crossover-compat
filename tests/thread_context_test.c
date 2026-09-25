/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <windows.h>
#include <stdio.h>
typedef LONG (WINAPI *lookup_fn)(HANDLE,void **);
typedef LONG (WINAPI *context_fn)(void *,CONTEXT *,UCHAR);
typedef void (WINAPI *release_fn)(void *);
static DWORD WINAPI worker(void *arg) { (void)arg; return 0; }
int main(void)
{
    HMODULE k=LoadLibraryA("ntoskrnl.exe");
    lookup_fn lookup=(lookup_fn)(void *)GetProcAddress(k,"PsLookupThreadByThreadId");
    context_fn query=(context_fn)(void *)GetProcAddress(k,"PsGetContextThread");
    release_fn release=(release_fn)(void *)GetProcAddress(k,"ObfDereferenceObject");
    DWORD id; void *object; CONTEXT a={0},b={0};
    HANDLE thread=CreateThread(NULL,0,worker,NULL,CREATE_SUSPENDED,&id);
    if(!thread||!lookup||!query||!release)return 1;
    if(lookup((HANDLE)(ULONG_PTR)id,&object))return 2;
    a.ContextFlags=b.ContextFlags=CONTEXT_CONTROL|CONTEXT_INTEGER;
    if(!GetThreadContext(thread,&a))return 3;
    LONG status=query(object,&b,1);
    LONG unsupported=query(object,&b,0);
    int valid=!status && a.Rip==b.Rip && a.Rsp==b.Rsp && a.Rcx==b.Rcx && unsupported<0;
    printf("user_status=%08lx registers_match=%d kernel_status=%08lx\n",status,valid,unsupported);
    release(object);ResumeThread(thread);WaitForSingleObject(thread,5000);CloseHandle(thread);
    return !valid;
}
