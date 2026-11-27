#ifndef CW_NOTIFY_H
#define CW_NOTIFY_H
#include <stdint.h>
#include <notify.h>
static inline uint32_t CWNotifyRegister(const char *name, int32_t *token) {
    return notify_register_check(name, token);
}
static inline uint32_t CWNotifyCancel(int32_t token) { return notify_cancel(token); }
static inline uint32_t CWNotifyGetState(int32_t token, uint64_t *state) {
    return notify_get_state(token, state);
}
static inline uint32_t CWNotifySetState(int32_t token, uint64_t state) {
    return notify_set_state(token, state);
}
#endif
