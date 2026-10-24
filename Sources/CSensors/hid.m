// HID temperature reader, adapted from exelban/stats (MIT)
// Modules/Sensors/reader.m, itself based on yujitach/MenuMeters.

#import <Foundation/Foundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include "CSensors.h"

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

#define IOHIDEventFieldBase(type) (type << 16)
#define kIOHIDEventTypeTemperature 15

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

static IOHIDEventSystemClientRef gClient = NULL;
static CFArrayRef gServices = NULL;
static NSTimeInterval gLastDiscovery = 0;

void CSensorsResetHID(void) {
    if (gServices) { CFRelease(gServices); gServices = NULL; }
    if (gClient) { CFRelease(gClient); gClient = NULL; }
    gLastDiscovery = 0;
}

CFDictionaryRef CSensorsCopyHIDTemperatures(void) {
    @autoreleasepool {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (!gClient) {
            gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
            if (!gClient) { return CFBridgingRetain(@{}); }
            // kHIDPage_AppleVendor / kHIDUsage_AppleVendor_TemperatureSensor
            NSDictionary *matching = @{@"PrimaryUsagePage": @(0xff00), @"PrimaryUsage": @(0x0005)};
            IOHIDEventSystemClientSetMatching(gClient, (__bridge CFDictionaryRef)matching);
        }
        if (!gServices || now - gLastDiscovery >= 60) {
            if (gServices) { CFRelease(gServices); }
            gServices = NULL;
            gLastDiscovery = now;
            // Each CopyEvent is a slow PMU round-trip, so keep only the sensors we display.
            CFArrayRef all = IOHIDEventSystemClientCopyServices(gClient);
            if (all) {
                CFMutableArrayRef keep = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
                for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
                    IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(all, i);
                    NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, CFSTR("Product")));
                    if ([name hasPrefix:@"PMU tdie"] || [name hasPrefix:@"NAND"] || [name hasPrefix:@"gas gauge"]) {
                        CFArrayAppendValue(keep, service);
                    }
                }
                CFRelease(all);
                gServices = keep;
            }
        }
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        if (!gServices) { return CFBridgingRetain(dict); }

        for (CFIndex i = 0; i < CFArrayGetCount(gServices); i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices, i);
            NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, CFSTR("Product")));
            IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
            if (!event) { continue; }
            double value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
            if (name && value > 0 && value < 130) { dict[name] = @(value); }
            CFRelease(event);
        }
        return CFBridgingRetain(dict);
    }
}

CFDictionaryRef CSensorsCopyAllHIDTemperatures(void) {
    @autoreleasepool {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) { return CFBridgingRetain(dict); }
        NSDictionary *matching = @{@"PrimaryUsagePage": @(0xff00), @"PrimaryUsage": @(0x0005)};
        IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matching);
        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        for (CFIndex i = 0; services && i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, CFSTR("Product")));
            IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
            if (!event) { continue; }
            double value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
            if (name && value > 0 && value < 130) { dict[name] = @(value); }
            CFRelease(event);
        }
        if (services) { CFRelease(services); }
        CFRelease(client);
        return CFBridgingRetain(dict);
    }
}
