#pragma once
// rootless.h 由 libroot / ElleKit SDK 提供；若构建环境暂时没有，
// 退化为原样路径，保证骨架在 WSL2 上仍可编译。
#if __has_include(<rootless.h>)
#import <rootless.h>
#else
#define ROOT_PATH(path) (path)
#define ROOT_PATH_NS(path) (path)
#endif
