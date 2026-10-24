// Minimal read-only AppleSMC client. Struct layout matches the AppleSMC
// kernel user client (same as exelban/stats SMC/smc.swift, MIT).

#include <IOKit/IOKitLib.h>
#include <string.h>
#include "CSensors.h"

enum { kKernelIndexSMC = 2, kSMCReadBytes = 5, kSMCReadIndex = 8, kSMCReadKeyInfo = 9 };

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static io_connect_t gConn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static void unfourcc(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
}

static bool call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(gConn, kKernelIndexSMC, in, sizeof(SMCKeyData), out, &outSize) == kIOReturnSuccess
        && out->result == 0;
}

bool SMCOpen(void) {
    if (gConn) { return true; }
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) { return false; }
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gConn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) { gConn = 0; return false; }
    return true;
}

void SMCClose(void) {
    if (gConn) { IOServiceClose(gConn); gConn = 0; }
}

// Key metadata never changes; caching it halves the IOKit round-trips per read.
#define INFO_CACHE 256
static struct { uint32_t key; SMCKeyInfo info; } gInfo[INFO_CACHE];
static int gInfoCount = 0;

static bool keyInfo(uint32_t key, SMCKeyInfo *info) {
    for (int i = 0; i < gInfoCount; i++) {
        if (gInfo[i].key == key) { *info = gInfo[i].info; return true; }
    }
    SMCKeyData in = {0}, out = {0};
    in.key = key;
    in.data8 = kSMCReadKeyInfo;
    if (!call(&in, &out)) { return false; }
    *info = out.keyInfo;
    if (gInfoCount < INFO_CACHE) { gInfo[gInfoCount].key = key; gInfo[gInfoCount].info = *info; gInfoCount++; }
    return true;
}

static bool readKey(uint32_t key, SMCKeyInfo *info, uint8_t bytes[32]) {
    SMCKeyData in = {0}, out = {0};
    if (!keyInfo(key, info)) { return false; }

    memset(&in, 0, sizeof in);
    in.key = key;
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = kSMCReadBytes;
    memset(&out, 0, sizeof out);
    if (!call(&in, &out)) { return false; }
    memcpy(bytes, out.bytes, 32);
    return true;
}

bool SMCReadDouble(const char *key, double *outValue) {
    if (!SMCOpen() || strlen(key) != 4) { return false; }
    SMCKeyInfo info; uint8_t b[32];
    if (!readKey(fourcc(key), &info, b) || info.dataSize == 0) { return false; }

    char type[5]; unfourcc(info.dataType, type);
    if (!strcmp(type, "flt ") && info.dataSize == 4) {
        float f; memcpy(&f, b, 4); *outValue = f; return true;
    }
    if (!strcmp(type, "ui8 ")) { *outValue = b[0]; return true; }
    if (!strcmp(type, "ui16")) { *outValue = (b[0] << 8) | b[1]; return true; }
    if (!strcmp(type, "ui32")) { *outValue = (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]); return true; }
    if (!strcmp(type, "sp78")) { *outValue = (double)(int16_t)((b[0] << 8) | b[1]) / 256.0; return true; }
    if (!strcmp(type, "fpe2")) { *outValue = (double)((b[0] << 8) | b[1]) / 4.0; return true; }
    if (!strcmp(type, "ioft") && info.dataSize == 8) {
        uint64_t v; memcpy(&v, b, 8); *outValue = (double)v / 65536.0; return true;
    }
    return false;
}

uint32_t SMCKeyCount(void) {
    double n = 0;
    return SMCReadDouble("#KEY", &n) ? (uint32_t)n : 0;
}

bool SMCKeyAtIndex(uint32_t index, char out[5]) {
    if (!SMCOpen()) { return false; }
    SMCKeyData in = {0}, o = {0};
    in.data8 = kSMCReadIndex;
    in.data32 = index;
    if (!call(&in, &o)) { return false; }
    unfourcc(o.key, out);
    return true;
}
