#include "CWNotify.h"
uint32_t CWNotifySDKProbe(const char *name) {
    int32_t token = -1;
    uint64_t state = 0;
    uint32_t status = CWNotifyRegister(name, &token);
    if (status != 0) return status;
    status = CWNotifySetState(token, 42);
    if (status == 0) status = CWNotifyGetState(token, &state);
    uint32_t cancelStatus = CWNotifyCancel(token);
    return status != 0 ? status : cancelStatus;
}
