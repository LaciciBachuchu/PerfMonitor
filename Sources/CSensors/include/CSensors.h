// Low-level sensor access for PerfMonitor.
// IOReport / IOHID declarations are private Apple APIs; signatures follow
// exelban/stats (MIT) Modules/Sensors/bridge.h.

#ifndef CSENSORS_H
#define CSENSORS_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdbool.h>
#include <notify.h>

// MARK: - IOReport

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef null);
IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef channels, CFMutableDictionaryRef *out, uint64_t d, CFTypeRef e);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef channels, CFTypeRef c);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef c);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef ch);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef ch);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef ch);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef ch);
int32_t IOReportStateGetCount(CFDictionaryRef ch);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef ch, int32_t idx);
int64_t IOReportStateGetResidency(CFDictionaryRef ch, int32_t idx);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef ch, int32_t idx);

// MARK: - HID temperature sensors (Apple Silicon)

/// Returns { sensorName: celsius } for every HID temperature sensor, or empty.
CFDictionaryRef CSensorsCopyHIDTemperatures(void);
void CSensorsResetHID(void);
/// Every HID temperature sensor (slow; for on-demand listings).
CFDictionaryRef CSensorsCopyAllHIDTemperatures(void);

// MARK: - SMC

bool SMCOpen(void);
void SMCClose(void);
/// Reads a numeric SMC key (e.g. "PSTR", "Tp01"). Returns false if missing/unsupported type.
bool SMCReadDouble(const char *key, double *out);
/// Number of SMC keys, and the key at an index (writes 5 bytes incl. NUL).
uint32_t SMCKeyCount(void);
bool SMCKeyAtIndex(uint32_t index, char out[5]);

#endif
