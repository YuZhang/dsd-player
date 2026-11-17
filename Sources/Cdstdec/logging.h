// 最小日志桩：libdstdec 只用到 LOG 宏与 lm_main 模块指针，全部置空
#ifndef __LOGGING_H__
#define __LOGGING_H__

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// 空模块指针（仅作宏参数占位）
static void *lm_main = (void *)0;

// LOG 宏全部为空操作
#define LOG(module, level, msg)  ((void)0)

#define LOG_NOTICE  0
#define LOG_ERROR   0

#ifdef __cplusplus
};
#endif

#endif /* __LOGGING_H__ */
