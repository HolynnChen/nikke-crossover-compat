/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <windows.h>
#include <stdio.h>
typedef void * (WINAPI *alloc_fn)(void *,ULONG,BOOLEAN,BOOLEAN,void *);
typedef void (WINAPI *lock_fn)(void *,UCHAR,int);
typedef void * (WINAPI *map_fn)(void *,UCHAR,int,void *,ULONG,ULONG);
typedef LONG (WINAPI *unmap_view_fn)(HANDLE,void *);
typedef void (WINAPI *unmap_mdl_fn)(void *,void *);
typedef void (WINAPI *one_fn)(void *);
#define API(type,name) type name=(type)(void *)GetProcAddress(k,#name); if(!name)return 2
int main(void)
{
    HMODULE k=LoadLibraryA("ntoskrnl.exe");
    API(alloc_fn,IoAllocateMdl); API(lock_fn,MmProbeAndLockPages);
    API(map_fn,MmMapLockedPagesSpecifyCache); API(unmap_view_fn,ZwUnmapViewOfSection);
    API(unmap_mdl_fn,MmUnmapLockedPages); API(one_fn,MmUnlockPages); API(one_fn,IoFreeMdl);
    HANDLE section=CreateFileMappingA(INVALID_HANDLE_VALUE,NULL,PAGE_READWRITE,0,0x4000,NULL);
    unsigned char *source=MapViewOfFile(section,FILE_MAP_ALL_ACCESS,0,0,0);
    unsigned char *alias=MapViewOfFile(section,FILE_MAP_ALL_ACCESS,0,0,0);
    MEMORY_BASIC_INFORMATION info;
    if(!source||!alias)return 3;
    void *a=IoAllocateMdl(source+0x100,0x100,FALSE,FALSE,NULL);
    void *b=IoAllocateMdl(source+0x900,0x1000,FALSE,FALSE,NULL);
    MmProbeAndLockPages(a,0,2); MmProbeAndLockPages(b,0,2);
    unsigned char *ma=MmMapLockedPagesSpecifyCache(a,0,1,NULL,0,0);
    unsigned char *mb=MmMapLockedPagesSpecifyCache(b,0,1,NULL,0,0);
    if(!ma||!mb)return 4;
    if(MmMapLockedPagesSpecifyCache(a,0,1,NULL,0,0)!=ma)return 5;
    if(ZwUnmapViewOfSection(GetCurrentProcess(),source+0x700))return 6;
    ma[0x23]=0x5a; mb[0x42]=0xa5;
    if(alias[0x123]!=0x5a||alias[0x942]!=0xa5)return 7;
    MmUnmapLockedPages(ma,a); MmUnlockPages(a); IoFreeMdl(a);
    if(!VirtualQuery(source,&info,sizeof(info))||info.State!=MEM_COMMIT)return 8;
    mb[0x42]=0x33; if(alias[0x942]!=0x33)return 9;
    MmUnlockPages(b); IoFreeMdl(b);
    if(!VirtualQuery(source,&info,sizeof(info))||info.State!=MEM_FREE)return 10;
    UnmapViewOfFile(alias); CloseHandle(section);
    puts("PASS: shared contents, interior addresses, two MDL references, deferred release");
    return 0;
}
