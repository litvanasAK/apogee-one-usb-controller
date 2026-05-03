#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/USBSpec.h>
#import <IOUSBHost/IOUSBHost.h>
#include <math.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

enum {
    kApogeeVendorID = 0x0c60,
    kApogeeOneProductID = 0x0003,
    kAudioControlInterface = 0,

    kONEVendorSetLLMOutputAttenuation = 0x06,
    kONEVendorRemoteI2CWrite = 0x02,
    kONELLMRemoteI2CAddress = 0x50,
    kONELLMRemoteI2CControl = 0x2b,

    kUACRequestSetCur = 0x01,
    kUACRequestGetCur = 0x81,
    kUACRequestGetMin = 0x82,
    kUACRequestGetMax = 0x83,
    kUACRequestGetRes = 0x84,

    kUACFeatureMute = 0x01,
    kUACFeatureVolume = 0x02,
    kUACSelectorControl = 0x01,

    kOutputFeatureUnit = 2,
    kHeadphoneFeatureUnit = 22,
    kInputSelectorUnit = 7,
};

static const char *kApogeeLegacyDaemonDirectory = "/var/run/com.apogee.soloDaemon";
static const char *kApogeeLegacyDaemonSocket = "/var/run/com.apogee.soloDaemon/Socket";
static const char *kApogeeLegacyONEDaemon = "/Library/Audio/Plug-Ins/HAL/Apogee/ONE/ONEPlugIn.bundle/Contents/MacOS/ONEDaemon";
static const char *kApogeeLegacyONEPlugIn = "/Library/Audio/Plug-Ins/HAL/Apogee/ONE/ONEPlugIn.bundle/Contents/MacOS/ONEPlugIn";

typedef struct {
    uint8_t pin;
    uint8_t feature_unit;
    const char *name;
    const char *cli_name;
    const char *descriptor_hint;
} InputSource;

typedef struct {
    int16_t current;
    int16_t minimum;
    int16_t maximum;
    int16_t resolution;
    bool has_current;
    bool has_minimum;
    bool has_maximum;
    bool has_resolution;
} VolumeState;

typedef struct {
    UInt32 selector;
    const char *name;
} MaestroPropertyProbe;

static const InputSource kInputSources[] = {
    {1, 5, "Int Mic", "int-mic", "feature 5, terminal personal microphone"},
    {2, 11, "Ext Mic", "ext-mic", "feature 11, terminal microphone"},
    {3, 13, "Ext 48V Mic", "ext-48v-mic", "feature 13, terminal omni microphone"},
    {4, 9, "Inst", "inst", "feature 9, terminal type 0x0200"},
};

#define FOURCC(a, b, c, d) ((((UInt32)(a)) << 24) | (((UInt32)(b)) << 16) | (((UInt32)(c)) << 8) | ((UInt32)(d)))

static const MaestroPropertyProbe kMaestroPropertyProbes[] = {
    {FOURCC('A', 'E', 'l', '3'), "mainOutLevel"},
    {FOURCC('A', 'E', 'm', '3'), "mainOutMute"},
    {FOURCC('A', 'E', 'o', 'r'), "outputLevelRange"},
    {FOURCC('A', 'E', 'l', '1'), "headPhone1Level"},
    {FOURCC('A', 'E', 'm', '1'), "headPhone1Mute"},
    {FOURCC('A', 'E', 'm', 'g'), "micGain"},
    {FOURCC('A', 'E', 'g', 'r'), "gainRange"},
    {FOURCC('A', 'E', 'p', 'h'), "phantom"},
    {FOURCC('A', 'E', 'h', 'i'), "HiZ"},
    {FOURCC('A', 'E', 'O', 'C'), "ONEChannelSelectionID"},
    {FOURCC('A', 'E', 'O', 'D'), "ONEChannelSelectionIDs"},
    {FOURCC('A', 'E', 'O', 'E'), "ONEChannelSelectionNameForID"},
    {FOURCC('A', 'E', 'm', 'd'), "monitorDeviceID"},
    {FOURCC('A', 'E', 'm', 's'), "monitorDeviceIDs"},
    {FOURCC('A', 'E', 'm', 'o'), "monitorOutputID"},
    {FOURCC('A', 'E', 'o', 's'), "monitorOutputIDs"},
    {FOURCC('A', 'E', 'm', 'I'), "mixerIDs"},
    {FOURCC('A', 'E', 'M', 'I'), "mixerID"},
    {FOURCC('A', 'E', 'M', 'l'), "mixerLevel"},
    {FOURCC('A', 'E', 'M', 'R'), "mixerLevelRange"},
    {FOURCC('A', 'E', 'M', 'm'), "mixerMute"},
    {FOURCC('A', 'E', 'M', 's'), "mixerSolo"},
    {FOURCC('A', 'E', 'M', 'p'), "mixerPan"},
    {FOURCC('A', 'P', 'G', '1'), "mixerModelData"},
};

static uint16_t read_le16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static void write_le16(uint8_t *bytes, int16_t value) {
    uint16_t raw = (uint16_t)value;
    bytes[0] = (uint8_t)(raw & 0xff);
    bytes[1] = (uint8_t)((raw >> 8) & 0xff);
}

static double fixed_db_to_double(int16_t value) {
    return value / 256.0;
}

static int16_t double_to_fixed_db(double value) {
    return (int16_t)llround(value * 256.0);
}

static const InputSource *source_for_pin(uint8_t pin) {
    for (size_t i = 0; i < sizeof(kInputSources) / sizeof(kInputSources[0]); i++) {
        if (kInputSources[i].pin == pin) {
            return &kInputSources[i];
        }
    }
    return NULL;
}

static const InputSource *source_for_feature_unit(uint8_t feature_unit) {
    for (size_t i = 0; i < sizeof(kInputSources) / sizeof(kInputSources[0]); i++) {
        if (kInputSources[i].feature_unit == feature_unit) {
            return &kInputSources[i];
        }
    }
    return NULL;
}

static const InputSource *source_for_name(const char *name) {
    for (size_t i = 0; i < sizeof(kInputSources) / sizeof(kInputSources[0]); i++) {
        if (strcasecmp(name, kInputSources[i].cli_name) == 0 ||
            strcasecmp(name, kInputSources[i].name) == 0) {
            return &kInputSources[i];
        }
    }

    if (strcasecmp(name, "internal") == 0 || strcasecmp(name, "internal-mic") == 0) {
        return source_for_pin(1);
    }
    if (strcasecmp(name, "external") == 0 || strcasecmp(name, "external-mic") == 0) {
        return source_for_pin(2);
    }
    if (strcasecmp(name, "external-48v") == 0 ||
        strcasecmp(name, "external-48v-mic") == 0 ||
        strcasecmp(name, "ext-mic-48v") == 0) {
        return source_for_pin(3);
    }
    if (strcasecmp(name, "instrument") == 0 ||
        strcasecmp(name, "hi-z") == 0 ||
        strcasecmp(name, "hiz") == 0) {
        return source_for_pin(4);
    }

    return NULL;
}

static void print_nserror(const char *context, NSError *error) {
    if (error) {
        fprintf(stderr,
                "%s failed: %s (domain=%s code=%ld)\n",
                context,
                error.localizedDescription.UTF8String,
                error.domain.UTF8String,
                (long)error.code);
    } else {
        fprintf(stderr, "%s failed\n", context);
    }
}

static void print_usage(void) {
    puts("Usage:");
    puts("  one-control status [--json]");
    puts("  one-control output [--json] [--volume-db <db>] [--mute on|off] [--headphone-mute on|off]");
    puts("  one-control input [--json] [--source <int-mic|ext-mic|ext-48v-mic|inst>]");
    puts("                    [--source-pin <1..4>|--source-unit <5|9|11|13>] [--gain-db <db>]");
    puts("  one-control monitor [--json] [--dry-run] [--volume-db <db>|--attenuation-db <db>]");
    puts("  one-control monitor [--json] [--dry-run] [--legacy-volume-db <db>|--legacy-attenuation-db <db>]");
    puts("  one-control monitor [--json] --mix-dry-run --ext-mic-level <0..63> --inst-int-level <0..63>");
    puts("  one-control monitor [--json] --mix-levels --ext-mic-level <0..63> --inst-int-level <0..63>");
    puts("  one-control self-test");
    puts("");
    puts("Notes:");
    puts("  input source labels are read from Core Audio selector item names on the live ONE.");
    puts("  ext-48v-mic selects the 48V external microphone mode.");
    puts("  monitor volume uses the confirmed direct-input monitor mix send.");
    puts("  monitor --volume-db accepts -63..0 dB; --attenuation-db accepts 0..63 dB.");
    puts("  legacy monitor attenuation uses the accepted but inaudible request 0x06.");
    puts("  monitor --dry-run prints the vendor request without sending it to the device.");
    puts("  monitor --mix-dry-run prints the direct-input monitor mix request only.");
    puts("  monitor --mix-levels sends the reverse-engineered direct-input monitor mix request.");
    puts("  self-test writes current values back to the device and verifies they round-trip.");
}

static int print_json_object(id object) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:object
                                                   options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                                     error:&error];
    if (!json) {
        print_nserror("JSON serialization", error);
        return 1;
    }

    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    return 0;
}

static bool parse_on_off(const char *text, uint8_t *value) {
    if (strcmp(text, "on") == 0 || strcmp(text, "1") == 0 || strcmp(text, "true") == 0) {
        *value = 1;
        return true;
    }
    if (strcmp(text, "off") == 0 || strcmp(text, "0") == 0 || strcmp(text, "false") == 0) {
        *value = 0;
        return true;
    }
    return false;
}

static bool parse_u8_arg(const char *text, uint8_t *value) {
    char *end = NULL;
    long parsed = strtol(text, &end, 0);
    if (!end || *end != '\0' || parsed < 0 || parsed > 255) {
        return false;
    }
    *value = (uint8_t)parsed;
    return true;
}

static bool parse_double_arg(const char *text, double *value) {
    char *end = NULL;
    double parsed = strtod(text, &end);
    if (!end || *end != '\0') {
        return false;
    }
    *value = parsed;
    return true;
}

static bool open_one_device(IOUSBHostDevice **out_device) {
    *out_device = nil;

    CFMutableDictionaryRef matching = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(kApogeeVendorID)
                                                                                  productID:@(kApogeeOneProductID)
                                                                                  bcdDevice:nil
                                                                                deviceClass:nil
                                                                             deviceSubclass:nil
                                                                             deviceProtocol:nil
                                                                                      speed:nil
                                                                             productIDArray:nil];
    if (!matching) {
        fputs("Could not create IOUSBHostDevice matching dictionary.\n", stderr);
        return false;
    }

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (service == IO_OBJECT_NULL) {
        fputs("Apogee ONE USB device 0x0c60:0x0003 was not found.\n", stderr);
        return false;
    }

    NSError *error = nil;
    dispatch_queue_t queue = dispatch_queue_create("one-control.usb", DISPATCH_QUEUE_SERIAL);
    IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:service
                                                                 options:IOUSBHostObjectInitOptionsNone
                                                                   queue:queue
                                                                   error:&error
                                                         interestHandler:nil];
    IOObjectRelease(service);

    if (!device) {
        print_nserror("IOUSBHostDevice init", error);
        fputs("The Codex sandbox can block IOUSBHost access; run outside the sandbox if needed.\n", stderr);
        return false;
    }

    *out_device = device;
    return true;
}

static bool send_uac_control(IOUSBHostDevice *device,
                             bool write,
                             uint8_t request,
                             uint8_t entity_id,
                             uint8_t control_selector,
                             uint8_t channel,
                             NSMutableData *data,
                             NSUInteger *bytes_transferred) {
    IOUSBDeviceRequest usb_request = {
        .bmRequestType = IOUSBHostDeviceRequestType(write ? kIOUSBDeviceRequestDirectionValueOut
                                                          : kIOUSBDeviceRequestDirectionValueIn,
                                                    kIOUSBDeviceRequestTypeValueClass,
                                                    kIOUSBDeviceRequestRecipientValueInterface),
        .bRequest = request,
        .wValue = (uint16_t)(((uint16_t)control_selector << 8) | channel),
        .wIndex = (uint16_t)(((uint16_t)entity_id << 8) | kAudioControlInterface),
        .wLength = (uint16_t)data.length,
    };

    NSError *error = nil;
    BOOL ok = [device sendDeviceRequest:usb_request
                                   data:data
                       bytesTransferred:bytes_transferred
                      completionTimeout:1.0
                                  error:&error];
    if (!ok) {
        char context[128];
        snprintf(context,
                 sizeof(context),
                 "%s entity=%u control=%u channel=%u",
                 write ? "SET_CUR" : "GET",
                 entity_id,
                 control_selector,
                 channel);
        print_nserror(context, error);
    }
    return ok;
}

static bool send_vendor_no_data_request(IOUSBHostDevice *device,
                                        uint8_t request,
                                        int16_t value,
                                        uint16_t index) {
    IOUSBDeviceRequest usb_request = {
        .bmRequestType = IOUSBHostDeviceRequestType(kIOUSBDeviceRequestDirectionValueOut,
                                                    kIOUSBDeviceRequestTypeValueVendor,
                                                    kIOUSBDeviceRequestRecipientValueDevice),
        .bRequest = request,
        .wValue = (uint16_t)value,
        .wIndex = index,
        .wLength = 0,
    };

    NSMutableData *data = [NSMutableData dataWithLength:0];
    NSUInteger bytes = 0;
    NSError *error = nil;
    BOOL ok = [device sendDeviceRequest:usb_request
                                   data:data
                       bytesTransferred:&bytes
                      completionTimeout:1.0
                                  error:&error];
    if (!ok) {
        char context[128];
        snprintf(context,
                 sizeof(context),
                 "vendor request=0x%02x value=%d index=%u",
                 request,
                 value,
                 index);
        print_nserror(context, error);
    }
    return ok;
}

static bool send_vendor_out_request(IOUSBHostDevice *device,
                                    uint8_t request,
                                    uint16_t value,
                                    uint16_t index,
                                    const uint8_t *bytes,
                                    NSUInteger length) {
    IOUSBDeviceRequest usb_request = {
        .bmRequestType = IOUSBHostDeviceRequestType(kIOUSBDeviceRequestDirectionValueOut,
                                                    kIOUSBDeviceRequestTypeValueVendor,
                                                    kIOUSBDeviceRequestRecipientValueDevice),
        .bRequest = request,
        .wValue = value,
        .wIndex = index,
        .wLength = (uint16_t)length,
    };

    NSMutableData *data = bytes ? [NSMutableData dataWithBytes:bytes length:length]
                                : [NSMutableData dataWithLength:length];
    NSUInteger transferred = 0;
    NSError *error = nil;
    BOOL ok = [device sendDeviceRequest:usb_request
                                   data:data
                       bytesTransferred:&transferred
                      completionTimeout:1.0
                                  error:&error];
    if (!ok) {
        char context[160];
        snprintf(context,
                 sizeof(context),
                 "vendor request=0x%02x value=0x%04x index=%u length=%lu",
                 request,
                 value,
                 index,
                 (unsigned long)length);
        print_nserror(context, error);
    }
    return ok;
}

static bool read_u8(IOUSBHostDevice *device,
                    uint8_t request,
                    uint8_t entity_id,
                    uint8_t control_selector,
                    uint8_t *value) {
    NSMutableData *data = [NSMutableData dataWithLength:1];
    NSUInteger bytes = 0;
    if (!send_uac_control(device, false, request, entity_id, control_selector, 0, data, &bytes) ||
        bytes < 1) {
        return false;
    }
    *value = ((const uint8_t *)data.bytes)[0];
    return true;
}

static bool write_u8(IOUSBHostDevice *device,
                     uint8_t entity_id,
                     uint8_t control_selector,
                     uint8_t value) {
    NSMutableData *data = [NSMutableData dataWithBytes:&value length:1];
    NSUInteger bytes = 0;
    return send_uac_control(device, true, kUACRequestSetCur, entity_id, control_selector, 0, data, &bytes);
}

static bool read_mute(IOUSBHostDevice *device, uint8_t entity_id, uint8_t *mute) {
    return read_u8(device, kUACRequestGetCur, entity_id, kUACFeatureMute, mute);
}

static bool write_mute(IOUSBHostDevice *device, uint8_t entity_id, uint8_t mute) {
    return write_u8(device, entity_id, kUACFeatureMute, mute);
}

static bool read_s16(IOUSBHostDevice *device,
                     uint8_t request,
                     uint8_t entity_id,
                     uint8_t control_selector,
                     int16_t *value) {
    NSMutableData *data = [NSMutableData dataWithLength:2];
    NSUInteger bytes = 0;
    if (!send_uac_control(device, false, request, entity_id, control_selector, 0, data, &bytes) ||
        bytes < 2) {
        return false;
    }
    *value = (int16_t)read_le16((const uint8_t *)data.bytes);
    return true;
}

static bool write_s16(IOUSBHostDevice *device,
                      uint8_t entity_id,
                      uint8_t control_selector,
                      int16_t value) {
    uint8_t bytes[2] = {0, 0};
    write_le16(bytes, value);
    NSMutableData *data = [NSMutableData dataWithBytes:bytes length:sizeof(bytes)];
    NSUInteger transferred = 0;
    return send_uac_control(device, true, kUACRequestSetCur, entity_id, control_selector, 0, data, &transferred);
}

static VolumeState read_volume_state(IOUSBHostDevice *device, uint8_t entity_id) {
    VolumeState state = {0};
    state.has_current = read_s16(device, kUACRequestGetCur, entity_id, kUACFeatureVolume, &state.current);
    state.has_minimum = read_s16(device, kUACRequestGetMin, entity_id, kUACFeatureVolume, &state.minimum);
    state.has_maximum = read_s16(device, kUACRequestGetMax, entity_id, kUACFeatureVolume, &state.maximum);
    state.has_resolution = read_s16(device, kUACRequestGetRes, entity_id, kUACFeatureVolume, &state.resolution);
    return state;
}

static bool validate_db_value(VolumeState state, double db, int16_t *fixed_value) {
    if (!state.has_minimum || !state.has_maximum) {
        fputs("Cannot set volume: device did not return min/max range.\n", stderr);
        return false;
    }

    int16_t fixed = double_to_fixed_db(db);
    if (fixed < state.minimum || fixed > state.maximum) {
        fprintf(stderr,
                "Value %.2f dB is outside range %.2f..%.2f dB.\n",
                db,
                fixed_db_to_double(state.minimum),
                fixed_db_to_double(state.maximum));
        return false;
    }

    *fixed_value = fixed;
    return true;
}

static void print_volume_line(const char *label, uint8_t entity_id, VolumeState state) {
    printf("%s (feature %u): ", label, entity_id);
    if (state.has_current) {
        printf("%.2f dB", fixed_db_to_double(state.current));
    } else {
        printf("unavailable");
    }
    if (state.has_minimum && state.has_maximum) {
        printf(" [%.2f..%.2f dB]", fixed_db_to_double(state.minimum), fixed_db_to_double(state.maximum));
    }
    if (state.has_resolution) {
        printf(" step %.2f dB", fixed_db_to_double(state.resolution));
    }
    printf("\n");
}

static void print_mute_line(IOUSBHostDevice *device, const char *label, uint8_t entity_id) {
    uint8_t mute = 0;
    if (read_mute(device, entity_id, &mute)) {
        printf("%s mute (feature %u): %s\n", label, entity_id, mute ? "on" : "off");
    } else {
        printf("%s mute (feature %u): unavailable\n", label, entity_id);
    }
}

static bool current_source(IOUSBHostDevice *device, const InputSource **source, uint8_t *pin) {
    uint8_t current_pin = 0;
    if (!read_u8(device, kUACRequestGetCur, kInputSelectorUnit, kUACSelectorControl, &current_pin)) {
        return false;
    }

    const InputSource *current = source_for_pin(current_pin);
    if (!current) {
        fprintf(stderr, "Input selector returned unknown pin %u.\n", current_pin);
        return false;
    }

    if (source) {
        *source = current;
    }
    if (pin) {
        *pin = current_pin;
    }
    return true;
}

static void print_input_source(IOUSBHostDevice *device) {
    const InputSource *source = NULL;
    uint8_t pin = 0;
    if (current_source(device, &source, &pin)) {
        printf("input source: %s (%s), pin %u -> feature %u (%s)\n",
               source->name,
               source->cli_name,
               pin,
               source->feature_unit,
               source->descriptor_hint);
    } else {
        puts("input source: unavailable");
    }
    puts("input source pins:");
    for (size_t i = 0; i < sizeof(kInputSources) / sizeof(kInputSources[0]); i++) {
        printf("  pin %u %-12s (%s) -> feature %u (%s)\n",
               kInputSources[i].pin,
               kInputSources[i].name,
               kInputSources[i].cli_name,
               kInputSources[i].feature_unit,
               kInputSources[i].descriptor_hint);
    }
}

static bool set_input_source(IOUSBHostDevice *device, const InputSource *source) {
    return write_u8(device, kInputSelectorUnit, kUACSelectorControl, source->pin);
}

static bool set_volume_db(IOUSBHostDevice *device, uint8_t entity_id, double db) {
    VolumeState state = read_volume_state(device, entity_id);
    int16_t fixed = 0;
    if (!validate_db_value(state, db, &fixed)) {
        return false;
    }
    return write_s16(device, entity_id, kUACFeatureVolume, fixed);
}

static bool set_volume_fixed(IOUSBHostDevice *device, uint8_t entity_id, int16_t fixed) {
    VolumeState state = read_volume_state(device, entity_id);
    if (!state.has_minimum || !state.has_maximum) {
        fputs("Cannot set volume: device did not return min/max range.\n", stderr);
        return false;
    }
    if (fixed < state.minimum || fixed > state.maximum) {
        fprintf(stderr,
                "Fixed volume %.2f dB is outside range %.2f..%.2f dB.\n",
                fixed_db_to_double(fixed),
                fixed_db_to_double(state.minimum),
                fixed_db_to_double(state.maximum));
        return false;
    }
    return write_s16(device, entity_id, kUACFeatureVolume, fixed);
}

static bool monitor_attenuation_request_value(double attenuation_db,
                                              int *rounded_attenuation,
                                              int16_t *request_value) {
    int rounded = (int)llround(attenuation_db);
    if (rounded < 0 || rounded > 96) {
        fprintf(stderr, "Monitor attenuation %.2f dB is outside range 0..96 dB.\n", attenuation_db);
        return false;
    }

    if (rounded_attenuation) {
        *rounded_attenuation = rounded;
    }
    if (request_value) {
        *request_value = (int16_t)-rounded;
    }

    return true;
}

static bool set_monitor_attenuation_db(IOUSBHostDevice *device,
                                       double attenuation_db,
                                       int *rounded_attenuation,
                                       int16_t *request_value) {
    int rounded = 0;
    int16_t value = 0;
    if (!monitor_attenuation_request_value(attenuation_db, &rounded, &value)) {
        return false;
    }

    if (rounded_attenuation) {
        *rounded_attenuation = rounded;
    }
    if (request_value) {
        *request_value = value;
    }

    return send_vendor_no_data_request(device,
                                       kONEVendorSetLLMOutputAttenuation,
                                       value,
                                       0);
}

static bool validate_llm_mix_level(const char *label, uint8_t level) {
    if (level > 63) {
        fprintf(stderr, "%s %u is outside range 0..63.\n", label, level);
        return false;
    }
    return true;
}

static bool monitor_mix_raw_from_attenuation_db(double attenuation_db, uint8_t *raw_level) {
    int rounded = (int)llround(attenuation_db);
    if (rounded < 0 || rounded > 63) {
        fprintf(stderr, "Monitor attenuation %.2f dB is outside range 0..63 dB.\n", attenuation_db);
        return false;
    }
    *raw_level = (uint8_t)rounded;
    return true;
}

static bool monitor_mix_raw_from_volume_db(double volume_db, uint8_t *raw_level) {
    if (volume_db < -63 || volume_db > 0) {
        fprintf(stderr, "Monitor volume %.2f dB is outside range -63..0 dB.\n", volume_db);
        return false;
    }
    return monitor_mix_raw_from_attenuation_db(-volume_db, raw_level);
}

static void monitor_mix_levels_for_source(const InputSource *source,
                                          uint8_t raw_level,
                                          uint8_t *ext_mic_level,
                                          uint8_t *inst_int_level) {
    *ext_mic_level = 63;
    *inst_int_level = 63;
    if (source && (source->pin == 2 || source->pin == 3)) {
        *ext_mic_level = raw_level;
    } else {
        *inst_int_level = raw_level;
    }
}

static void print_llm_mix_dry_run(uint8_t ext_mic_level, uint8_t inst_int_level) {
    uint16_t value = (uint16_t)(((uint16_t)(kONELLMRemoteI2CControl & 0x3f) << 8) |
                                kONELLMRemoteI2CAddress);
    uint8_t payload = (uint8_t)(0x40 | inst_int_level);

    printf("monitor: dry run; would send direct input monitor mix ext-mic=%u inst/int=%u\n",
           ext_mic_level,
           inst_int_level);
    printf("monitor: vendor OUT request bmRequestType=0x40 bRequest=0x%02x wValue=0x%04x wIndex=%u wLength=1 data=0x%02x\n",
           kONEVendorRemoteI2CWrite,
           value,
           ext_mic_level,
           payload);
    puts("monitor: use --mix-levels with the same arguments to send this request.");
}

static bool set_llm_mix_levels(IOUSBHostDevice *device, uint8_t ext_mic_level, uint8_t inst_int_level) {
    uint16_t value = (uint16_t)(((uint16_t)(kONELLMRemoteI2CControl & 0x3f) << 8) |
                                kONELLMRemoteI2CAddress);
    uint8_t payload = (uint8_t)(0x40 | inst_int_level);
    return send_vendor_out_request(device,
                                   kONEVendorRemoteI2CWrite,
                                   value,
                                   ext_mic_level,
                                   &payload,
                                   sizeof(payload));
}

static UInt32 coreaudio_property_size(AudioObjectID object_id,
                                      AudioObjectPropertySelector selector,
                                      AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (!AudioObjectHasProperty(object_id, &address) ||
        AudioObjectGetPropertyDataSize(object_id, &address, 0, NULL, &size) != noErr) {
        return 0;
    }
    return size;
}

static bool coreaudio_get(AudioObjectID object_id,
                          AudioObjectPropertySelector selector,
                          AudioObjectPropertyScope scope,
                          void *data,
                          UInt32 *size) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    return AudioObjectHasProperty(object_id, &address) &&
           AudioObjectGetPropertyData(object_id, &address, 0, NULL, size, data) == noErr;
}

static bool coreaudio_get_qualified(AudioObjectID object_id,
                                    AudioObjectPropertySelector selector,
                                    AudioObjectPropertyScope scope,
                                    const void *qualifier,
                                    UInt32 qualifier_size,
                                    void *data,
                                    UInt32 *size) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    return AudioObjectHasProperty(object_id, &address) &&
           AudioObjectGetPropertyData(object_id, &address, qualifier_size, qualifier, size, data) == noErr;
}

static CFStringRef coreaudio_copy_string(AudioObjectID object_id, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (!coreaudio_get(object_id, selector, kAudioObjectPropertyScopeGlobal, &value, &size)) {
        return NULL;
    }
    return value;
}

static CFStringRef coreaudio_copy_selector_item_name(AudioObjectID control_id, UInt32 item_id) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (!coreaudio_get_qualified(control_id,
                                 kAudioSelectorControlPropertyItemName,
                                 kAudioObjectPropertyScopeGlobal,
                                 &item_id,
                                 sizeof(item_id),
                                 &value,
                                 &size)) {
        return NULL;
    }
    return value;
}

static bool coreaudio_get_selector_item_kind(AudioObjectID control_id, UInt32 item_id, UInt32 *kind) {
    UInt32 size = sizeof(*kind);
    return coreaudio_get_qualified(control_id,
                                   kAudioSelectorControlPropertyItemKind,
                                   kAudioObjectPropertyScopeGlobal,
                                   &item_id,
                                   sizeof(item_id),
                                   kind,
                                   &size) &&
           size == sizeof(*kind);
}

static bool cfstring_contains_cstr(CFStringRef string, const char *needle) {
    if (!string) {
        return false;
    }
    CFStringRef needle_string = CFStringCreateWithCString(kCFAllocatorDefault, needle, kCFStringEncodingUTF8);
    if (!needle_string) {
        return false;
    }
    Boolean found = CFStringFind(string, needle_string, kCFCompareCaseInsensitive).location != kCFNotFound;
    CFRelease(needle_string);
    return found;
}

static void print_cfstring(CFStringRef string) {
    if (!string) {
        printf("(unavailable)");
        return;
    }

    char buffer[512];
    if (CFStringGetCString(string, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("%s", buffer);
    } else {
        printf("(unprintable)");
    }
}

static UInt32 coreaudio_channel_count(AudioObjectID device_id, AudioObjectPropertyScope scope) {
    UInt32 size = coreaudio_property_size(device_id, kAudioDevicePropertyStreamConfiguration, scope);
    if (size < sizeof(AudioBufferList)) {
        return 0;
    }

    AudioBufferList *buffer_list = calloc(1, size);
    if (!buffer_list) {
        return 0;
    }

    UInt32 channels = 0;
    if (coreaudio_get(device_id, kAudioDevicePropertyStreamConfiguration, scope, buffer_list, &size)) {
        for (UInt32 i = 0; i < buffer_list->mNumberBuffers; i++) {
            channels += buffer_list->mBuffers[i].mNumberChannels;
        }
    }

    free(buffer_list);
    return channels;
}

static AudioObjectID coreaudio_default_device(AudioObjectPropertySelector selector) {
    AudioObjectID value = kAudioObjectUnknown;
    UInt32 size = sizeof(value);
    if (!coreaudio_get(kAudioObjectSystemObject, selector, kAudioObjectPropertyScopeGlobal, &value, &size)) {
        return kAudioObjectUnknown;
    }
    return value;
}

static AudioObjectID find_coreaudio_one(void) {
    UInt32 size = coreaudio_property_size(kAudioObjectSystemObject,
                                          kAudioHardwarePropertyDevices,
                                          kAudioObjectPropertyScopeGlobal);
    if (size == 0) {
        return kAudioObjectUnknown;
    }

    AudioObjectID *devices = calloc(1, size);
    if (!devices) {
        return kAudioObjectUnknown;
    }

    if (!coreaudio_get(kAudioObjectSystemObject,
                       kAudioHardwarePropertyDevices,
                       kAudioObjectPropertyScopeGlobal,
                       devices,
                       &size)) {
        free(devices);
        return kAudioObjectUnknown;
    }

    AudioObjectID found = kAudioObjectUnknown;
    UInt32 count = size / sizeof(AudioObjectID);
    for (UInt32 i = 0; i < count; i++) {
        CFStringRef name = coreaudio_copy_string(devices[i], kAudioObjectPropertyName);
        CFStringRef manufacturer = coreaudio_copy_string(devices[i], kAudioObjectPropertyManufacturer);
        CFStringRef uid = coreaudio_copy_string(devices[i], kAudioDevicePropertyDeviceUID);

        bool matches = cfstring_contains_cstr(name, "ONE") &&
                       (cfstring_contains_cstr(manufacturer, "Apogee") ||
                        cfstring_contains_cstr(uid, "Apogee:ONE"));
        if (matches) {
            found = devices[i];
        }

        if (name) {
            CFRelease(name);
        }
        if (manufacturer) {
            CFRelease(manufacturer);
        }
        if (uid) {
            CFRelease(uid);
        }
        if (found != kAudioObjectUnknown) {
            break;
        }
    }

    free(devices);
    return found;
}

static bool coreaudio_has_property(AudioObjectID object_id,
                                   AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    return AudioObjectHasProperty(object_id, &address);
}

static const char *fourcc_string(UInt32 value, char buffer[5]) {
    buffer[0] = (char)((value >> 24) & 0xff);
    buffer[1] = (char)((value >> 16) & 0xff);
    buffer[2] = (char)((value >> 8) & 0xff);
    buffer[3] = (char)(value & 0xff);
    buffer[4] = 0;
    for (int i = 0; i < 4; i++) {
        if (buffer[i] < 32 || buffer[i] > 126) {
            buffer[i] = '.';
        }
    }
    return buffer;
}

static const char *coreaudio_class_name(UInt32 class_id) {
    switch (class_id) {
        case kAudioVolumeControlClassID: return "volume";
        case kAudioMuteControlClassID: return "mute";
        case kAudioBooleanControlClassID: return "boolean";
        case kAudioLevelControlClassID: return "level";
        case kAudioSelectorControlClassID: return "selector";
        case kAudioDataSourceControlClassID: return "data-source";
        case kAudioDataDestinationControlClassID: return "data-destination";
        case kAudioClockSourceControlClassID: return "clock-source";
        case kAudioLineLevelControlClassID: return "line-level";
        case kAudioHighPassFilterControlClassID: return "high-pass-filter";
        case kAudioPhantomPowerControlClassID: return "phantom-power";
        case kAudioPhaseInvertControlClassID: return "phase-invert";
        case kAudioJackControlClassID: return "jack";
        case kAudioStereoPanControlClassID: return "stereo-pan";
        default: return "unknown";
    }
}

static const char *coreaudio_scope_name(UInt32 scope) {
    switch (scope) {
        case kAudioObjectPropertyScopeGlobal: return "global";
        case kAudioObjectPropertyScopeInput: return "input";
        case kAudioObjectPropertyScopeOutput: return "output";
        case kAudioObjectPropertyScopePlayThrough: return "play-through";
        default: return "unknown";
    }
}

static bool coreaudio_get_uint32(AudioObjectID object_id,
                                 AudioObjectPropertySelector selector,
                                 AudioObjectPropertyScope scope,
                                 UInt32 *value) {
    UInt32 size = sizeof(*value);
    return coreaudio_get(object_id, selector, scope, value, &size) && size == sizeof(*value);
}

static bool coreaudio_get_float32(AudioObjectID object_id,
                                  AudioObjectPropertySelector selector,
                                  AudioObjectPropertyScope scope,
                                  Float32 *value) {
    UInt32 size = sizeof(*value);
    return coreaudio_get(object_id, selector, scope, value, &size) && size == sizeof(*value);
}

static bool coreaudio_get_range(AudioObjectID object_id,
                                AudioObjectPropertySelector selector,
                                AudioObjectPropertyScope scope,
                                AudioValueRange *range) {
    UInt32 size = sizeof(*range);
    return coreaudio_get(object_id, selector, scope, range, &size) && size == sizeof(*range);
}

static void print_coreaudio_control_values(AudioObjectID control_id) {
    Float32 scalar = 0;
    Float32 db = 0;
    AudioValueRange db_range = {0, 0};
    UInt32 boolean = 0;
    UInt32 selector = 0;
    bool printed = false;

    if (coreaudio_get_float32(control_id,
                              kAudioLevelControlPropertyScalarValue,
                              kAudioObjectPropertyScopeGlobal,
                              &scalar)) {
        printf(" scalar=%.3f", scalar);
        printed = true;
    }
    if (coreaudio_get_float32(control_id,
                              kAudioLevelControlPropertyDecibelValue,
                              kAudioObjectPropertyScopeGlobal,
                              &db)) {
        printf(" dB=%.2f", db);
        printed = true;
    }
    if (coreaudio_get_range(control_id,
                            kAudioLevelControlPropertyDecibelRange,
                            kAudioObjectPropertyScopeGlobal,
                            &db_range)) {
        printf(" dBRange=%.2f..%.2f", db_range.mMinimum, db_range.mMaximum);
        printed = true;
    }
    if (coreaudio_get_uint32(control_id,
                             kAudioBooleanControlPropertyValue,
                             kAudioObjectPropertyScopeGlobal,
                             &boolean)) {
        printf(" bool=%u", boolean);
        printed = true;
    }
    if (coreaudio_get_uint32(control_id,
                             kAudioSelectorControlPropertyCurrentItem,
                             kAudioObjectPropertyScopeGlobal,
                             &selector)) {
        printf(" currentItem=%u", selector);
        printed = true;
    }

    UInt32 available_size = coreaudio_property_size(control_id,
                                                   kAudioSelectorControlPropertyAvailableItems,
                                                   kAudioObjectPropertyScopeGlobal);
    if (available_size > 0 && available_size % sizeof(UInt32) == 0) {
        UInt32 *items = calloc(1, available_size);
        if (items) {
            UInt32 size = available_size;
            if (coreaudio_get(control_id,
                              kAudioSelectorControlPropertyAvailableItems,
                              kAudioObjectPropertyScopeGlobal,
                              items,
                              &size)) {
                printf(" items=[");
                UInt32 count = size / sizeof(UInt32);
                for (UInt32 i = 0; i < count; i++) {
                    printf("%s%u", i == 0 ? "" : ",", items[i]);
                    CFStringRef item_name = coreaudio_copy_selector_item_name(control_id, items[i]);
                    UInt32 item_kind = 0;
                    bool has_kind = coreaudio_get_selector_item_kind(control_id, items[i], &item_kind);
                    if (item_name) {
                        printf(":");
                        print_cfstring(item_name);
                    }
                    if (has_kind) {
                        char kind_fourcc[5];
                        printf(":kind=%s", fourcc_string(item_kind, kind_fourcc));
                    }
                    if (item_name) {
                        CFRelease(item_name);
                    }
                }
                printf("]");
                printed = true;
            }
            free(items);
        }
    }

    if (!printed) {
        printf(" values=(none-readable)");
    }
}

static void print_coreaudio_control_object(AudioObjectID control_id) {
    UInt32 class_id = 0;
    UInt32 scope = 0;
    UInt32 element = 0;
    char class_fourcc[5];
    char scope_fourcc[5];
    CFStringRef name = coreaudio_copy_string(control_id, kAudioObjectPropertyName);

    coreaudio_get_uint32(control_id, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, &class_id);
    coreaudio_get_uint32(control_id, kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal, &scope);
    coreaudio_get_uint32(control_id, kAudioControlPropertyElement, kAudioObjectPropertyScopeGlobal, &element);

    printf("  control %u class=%s(%s) scope=%s(%s) element=%u name=",
           control_id,
           fourcc_string(class_id, class_fourcc),
           coreaudio_class_name(class_id),
           fourcc_string(scope, scope_fourcc),
           coreaudio_scope_name(scope),
           element);
    print_cfstring(name);
    print_coreaudio_control_values(control_id);
    printf("\n");

    if (name) {
        CFRelease(name);
    }
}

static void print_coreaudio_controls(AudioObjectID device_id) {
    UInt32 size = coreaudio_property_size(device_id,
                                          kAudioObjectPropertyControlList,
                                          kAudioObjectPropertyScopeGlobal);
    if (size == 0 || size % sizeof(AudioObjectID) != 0) {
        puts("  Core Audio control list: unavailable");
        return;
    }

    AudioObjectID *controls = calloc(1, size);
    if (!controls) {
        puts("  Core Audio control list: allocation failed");
        return;
    }

    UInt32 read_size = size;
    if (!coreaudio_get(device_id,
                       kAudioObjectPropertyControlList,
                       kAudioObjectPropertyScopeGlobal,
                       controls,
                       &read_size)) {
        free(controls);
        puts("  Core Audio control list: read failed");
        return;
    }

    UInt32 count = read_size / sizeof(AudioObjectID);
    printf("  Core Audio control list: %u controls\n", count);
    for (UInt32 i = 0; i < count; i++) {
        print_coreaudio_control_object(controls[i]);
    }

    free(controls);
}

static void print_raw_property_preview(AudioObjectID object_id,
                                       AudioObjectPropertySelector selector,
                                       AudioObjectPropertyScope scope,
                                       UInt32 size) {
    if (size == 0 || size > 64) {
        return;
    }

    void *data = calloc(1, size);
    if (!data) {
        return;
    }

    UInt32 read_size = size;
    if (coreaudio_get(object_id, selector, scope, data, &read_size)) {
        const uint8_t *bytes = (const uint8_t *)data;
        printf(" raw=");
        for (UInt32 i = 0; i < read_size && i < 16; i++) {
            printf("%02x", bytes[i]);
        }
        if (read_size > 16) {
            printf("...");
        }
        if (read_size == sizeof(UInt32)) {
            UInt32 value = 0;
            memcpy(&value, data, sizeof(value));
            char fourcc[5];
            printf(" uint32=%u fourcc=%s", value, fourcc_string(value, fourcc));
        }
        if (read_size == sizeof(Float32)) {
            Float32 value = 0;
            memcpy(&value, data, sizeof(value));
            printf(" float32=%.3f", value);
        }
    } else {
        printf(" read=failed");
    }

    free(data);
}

static void print_maestro_property_probe(AudioObjectID device_id) {
    const AudioObjectPropertyScope scopes[] = {
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyScopeOutput,
    };

    puts("  Maestro property selectors:");
    bool any = false;
    for (size_t i = 0; i < sizeof(kMaestroPropertyProbes) / sizeof(kMaestroPropertyProbes[0]); i++) {
        for (size_t s = 0; s < sizeof(scopes) / sizeof(scopes[0]); s++) {
            AudioObjectPropertyAddress address = {
                .mSelector = kMaestroPropertyProbes[i].selector,
                .mScope = scopes[s],
                .mElement = kAudioObjectPropertyElementMain,
            };

            if (!AudioObjectHasProperty(device_id, &address)) {
                continue;
            }

            UInt32 size = 0;
            OSStatus status = AudioObjectGetPropertyDataSize(device_id, &address, 0, NULL, &size);
            char selector_fourcc[5];
            printf("    %s %s scope=%s",
                   fourcc_string(kMaestroPropertyProbes[i].selector, selector_fourcc),
                   kMaestroPropertyProbes[i].name,
                   coreaudio_scope_name(scopes[s]));
            if (status == noErr) {
                printf(" size=%u", size);
                print_raw_property_preview(device_id, kMaestroPropertyProbes[i].selector, scopes[s], size);
            } else {
                printf(" sizeStatus=%d", status);
            }
            printf("\n");
            any = true;
        }
    }

    if (!any) {
        puts("    none of the selected Apogee/Maestro selectors are exposed on the Core Audio device");
    }
}

static const char *stat_type_name(mode_t mode) {
    if (S_ISDIR(mode)) {
        return "directory";
    }
    if (S_ISREG(mode)) {
        return "regular-file";
    }
    if (S_ISSOCK(mode)) {
        return "socket";
    }
    if (S_ISLNK(mode)) {
        return "symlink";
    }
    return "other";
}

static void print_path_probe(const char *label, const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0) {
        printf("    %s: missing (%s): %s\n", label, strerror(errno), path);
        return;
    }

    printf("    %s: %s mode=%04o uid=%u gid=%u: %s\n",
           label,
           stat_type_name(info.st_mode),
           info.st_mode & 07777,
           info.st_uid,
           info.st_gid,
           path);
}

static void print_apogee_private_transport_discovery(void) {
    puts("  Apogee private transport:");
    print_path_probe("legacy ONE daemon", kApogeeLegacyONEDaemon);
    print_path_probe("legacy ONE HAL plug-in", kApogeeLegacyONEPlugIn);
    print_path_probe("legacy socket directory", kApogeeLegacyDaemonDirectory);

    struct stat socket_info;
    if (lstat(kApogeeLegacyDaemonSocket, &socket_info) != 0) {
        printf("    legacy socket: missing (%s): %s\n", strerror(errno), kApogeeLegacyDaemonSocket);
        puts("    socket status: unavailable; ONEDaemon is not accepting Maestro private-property traffic.");
        return;
    }

    printf("    legacy socket: %s mode=%04o uid=%u gid=%u: %s\n",
           stat_type_name(socket_info.st_mode),
           socket_info.st_mode & 07777,
           socket_info.st_uid,
           socket_info.st_gid,
           kApogeeLegacyDaemonSocket);

    if (!S_ISSOCK(socket_info.st_mode)) {
        puts("    socket status: path exists but is not a Unix-domain socket.");
        return;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        printf("    socket status: probe failed to create socket (%s)\n", strerror(errno));
        return;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, kApogeeLegacyDaemonSocket, sizeof(address.sun_path));

    if (connect(fd, (struct sockaddr *)&address, (socklen_t)sizeof(address)) == 0) {
        puts("    socket status: connectable (protocol still unmapped; no data sent)");
    } else {
        printf("    socket status: connect failed (%s)\n", strerror(errno));
    }
    close(fd);
}

static void print_coreaudio_status(void) {
    AudioObjectID one = find_coreaudio_one();
    if (one == kAudioObjectUnknown) {
        puts("Core Audio: ONE not visible in this process.");
        puts("Core Audio: sandboxed processes may see an empty device list.");
        return;
    }

    CFStringRef name = coreaudio_copy_string(one, kAudioObjectPropertyName);
    CFStringRef manufacturer = coreaudio_copy_string(one, kAudioObjectPropertyManufacturer);
    CFStringRef uid = coreaudio_copy_string(one, kAudioDevicePropertyDeviceUID);
    Float64 sample_rate = 0;
    UInt32 sample_rate_size = sizeof(sample_rate);
    coreaudio_get(one,
                  kAudioDevicePropertyNominalSampleRate,
                  kAudioObjectPropertyScopeGlobal,
                  &sample_rate,
                  &sample_rate_size);

    AudioObjectID default_input = coreaudio_default_device(kAudioHardwarePropertyDefaultInputDevice);
    AudioObjectID default_output = coreaudio_default_device(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectID default_system_output = coreaudio_default_device(kAudioHardwarePropertyDefaultSystemOutputDevice);

    printf("Core Audio: device id %u", one);
    if (one == default_input) {
        printf(" [default input]");
    }
    if (one == default_output) {
        printf(" [default output]");
    }
    if (one == default_system_output) {
        printf(" [default system output]");
    }
    printf("\n");

    printf("  name: ");
    print_cfstring(name);
    printf("\n");
    printf("  manufacturer: ");
    print_cfstring(manufacturer);
    printf("\n");
    printf("  uid: ");
    print_cfstring(uid);
    printf("\n");
    printf("  nominal sample rate: %.0f\n", sample_rate);
    printf("  channels: input=%u output=%u\n",
           coreaudio_channel_count(one, kAudioDevicePropertyScopeInput),
           coreaudio_channel_count(one, kAudioDevicePropertyScopeOutput));

    if (name) {
        CFRelease(name);
    }
    if (manufacturer) {
        CFRelease(manufacturer);
    }
    if (uid) {
        CFRelease(uid);
    }
}

static void print_monitor_discovery(void) {
    puts("monitor volume: confirmed direct-input mix send mapped");
    puts("  standard UAC descriptor dump shows output volume and input gain controls, not a named monitor volume control.");
    puts("  audible tests confirm the TAS1020 remote-I2C direct-input monitor mix send controls monitoring volume.");
    puts("  one-control exposes this as monitor --volume-db -63..0 or --attenuation-db 0..63.");
    puts("  raw mix values are inverted: 0 is loud, 63 is silent or near-silent.");
    puts("  legacy ONEDaemon request 0x06 is accepted by the device but did not change audible monitoring in tests.");

    AudioObjectID one = find_coreaudio_one();
    if (one == kAudioObjectUnknown) {
        puts("  Core Audio ONE device is not visible in this process.");
        return;
    }

    printf("  Core Audio play-through support: global=%s input=%s output=%s\n",
           coreaudio_has_property(one, kAudioDevicePropertyPlayThruVolumeDecibels, kAudioObjectPropertyScopeGlobal) ? "yes" : "no",
           coreaudio_has_property(one, kAudioDevicePropertyPlayThruVolumeDecibels, kAudioDevicePropertyScopeInput) ? "yes" : "no",
           coreaudio_has_property(one, kAudioDevicePropertyPlayThruVolumeDecibels, kAudioDevicePropertyScopeOutput) ? "yes" : "no");
    print_coreaudio_controls(one);
    print_maestro_property_probe(one);
    print_apogee_private_transport_discovery();
    puts("  next discovery target: calibrate the user-facing monitor curve and add state persistence.");
}

static id json_value_for_cfstring(CFStringRef string) {
    if (!string) {
        return [NSNull null];
    }
    return CFBridgingRelease(string);
}

static NSNumber *json_bool(bool value) {
    return value ? @YES : @NO;
}

static NSMutableDictionary *json_volume_state(VolumeState state) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (state.has_current) {
        [dict setObject:@(fixed_db_to_double(state.current)) forKey:@"currentDb"];
    }
    if (state.has_minimum) {
        [dict setObject:@(fixed_db_to_double(state.minimum)) forKey:@"minimumDb"];
    }
    if (state.has_maximum) {
        [dict setObject:@(fixed_db_to_double(state.maximum)) forKey:@"maximumDb"];
    }
    if (state.has_resolution) {
        [dict setObject:@(fixed_db_to_double(state.resolution)) forKey:@"resolutionDb"];
    }
    return dict;
}

static id json_mute_value(IOUSBHostDevice *device, uint8_t entity_id) {
    uint8_t mute = 0;
    if (!read_mute(device, entity_id, &mute)) {
        return [NSNull null];
    }
    return json_bool(mute != 0);
}

static NSDictionary *json_input_source(const InputSource *source) {
    if (!source) {
        return @{};
    }
    bool is_external_mic = source->pin == 2 || source->pin == 3;
    bool is_instrument = source->pin == 4;
    return @{
        @"pin": @(source->pin),
        @"featureUnit": @(source->feature_unit),
        @"name": @(source->name),
        @"cliName": @(source->cli_name),
        @"descriptorHint": @(source->descriptor_hint),
        @"phantomPower": json_bool(source->pin == 3),
        @"hiZ": json_bool(is_instrument),
        @"microphone": json_bool(!is_instrument),
        @"externalInput": json_bool(is_external_mic || is_instrument),
    };
}

static NSArray *json_input_sources(void) {
    NSMutableArray *sources = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kInputSources) / sizeof(kInputSources[0]); i++) {
        [sources addObject:json_input_source(&kInputSources[i])];
    }
    return sources;
}

static NSMutableDictionary *json_coreaudio_control_values(AudioObjectID control_id) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    Float32 scalar = 0;
    Float32 db = 0;
    AudioValueRange db_range = {0, 0};
    UInt32 boolean = 0;
    UInt32 selector = 0;

    if (coreaudio_get_float32(control_id,
                              kAudioLevelControlPropertyScalarValue,
                              kAudioObjectPropertyScopeGlobal,
                              &scalar)) {
        [values setObject:@(scalar) forKey:@"scalar"];
    }
    if (coreaudio_get_float32(control_id,
                              kAudioLevelControlPropertyDecibelValue,
                              kAudioObjectPropertyScopeGlobal,
                              &db)) {
        [values setObject:@(db) forKey:@"decibels"];
    }
    if (coreaudio_get_range(control_id,
                            kAudioLevelControlPropertyDecibelRange,
                            kAudioObjectPropertyScopeGlobal,
                            &db_range)) {
        [values setObject:@{
            @"minimum": @(db_range.mMinimum),
            @"maximum": @(db_range.mMaximum),
        } forKey:@"decibelRange"];
    }
    if (coreaudio_get_uint32(control_id,
                             kAudioBooleanControlPropertyValue,
                             kAudioObjectPropertyScopeGlobal,
                             &boolean)) {
        [values setObject:json_bool(boolean != 0) forKey:@"boolean"];
    }
    if (coreaudio_get_uint32(control_id,
                             kAudioSelectorControlPropertyCurrentItem,
                             kAudioObjectPropertyScopeGlobal,
                             &selector)) {
        [values setObject:@(selector) forKey:@"currentItem"];
    }

    UInt32 available_size = coreaudio_property_size(control_id,
                                                   kAudioSelectorControlPropertyAvailableItems,
                                                   kAudioObjectPropertyScopeGlobal);
    if (available_size > 0 && available_size % sizeof(UInt32) == 0) {
        UInt32 *items = calloc(1, available_size);
        if (items) {
            UInt32 size = available_size;
            if (coreaudio_get(control_id,
                              kAudioSelectorControlPropertyAvailableItems,
                              kAudioObjectPropertyScopeGlobal,
                              items,
                              &size)) {
                NSMutableArray *json_items = [NSMutableArray array];
                UInt32 count = size / sizeof(UInt32);
                for (UInt32 i = 0; i < count; i++) {
                    NSMutableDictionary *item = [@{@"id": @(items[i])} mutableCopy];
                    CFStringRef item_name = coreaudio_copy_selector_item_name(control_id, items[i]);
                    UInt32 item_kind = 0;
                    if (item_name) {
                        [item setObject:json_value_for_cfstring(item_name) forKey:@"name"];
                    }
                    if (coreaudio_get_selector_item_kind(control_id, items[i], &item_kind)) {
                        char kind_fourcc[5];
                        [item setObject:[NSString stringWithUTF8String:fourcc_string(item_kind, kind_fourcc)]
                                  forKey:@"kindFourCC"];
                    }
                    [json_items addObject:item];
                }
                [values setObject:json_items forKey:@"items"];
            }
            free(items);
        }
    }

    return values;
}

static NSArray *json_coreaudio_controls(AudioObjectID device_id) {
    UInt32 size = coreaudio_property_size(device_id,
                                          kAudioObjectPropertyControlList,
                                          kAudioObjectPropertyScopeGlobal);
    if (size == 0 || size % sizeof(AudioObjectID) != 0) {
        return @[];
    }

    AudioObjectID *controls = calloc(1, size);
    if (!controls) {
        return @[];
    }

    NSMutableArray *json_controls = [NSMutableArray array];
    UInt32 read_size = size;
    if (coreaudio_get(device_id,
                      kAudioObjectPropertyControlList,
                      kAudioObjectPropertyScopeGlobal,
                      controls,
                      &read_size)) {
        UInt32 count = read_size / sizeof(AudioObjectID);
        for (UInt32 i = 0; i < count; i++) {
            UInt32 class_id = 0;
            UInt32 scope = 0;
            UInt32 element = 0;
            char class_fourcc[5];
            char scope_fourcc[5];
            CFStringRef name = coreaudio_copy_string(controls[i], kAudioObjectPropertyName);

            coreaudio_get_uint32(controls[i], kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, &class_id);
            coreaudio_get_uint32(controls[i], kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal, &scope);
            coreaudio_get_uint32(controls[i], kAudioControlPropertyElement, kAudioObjectPropertyScopeGlobal, &element);

            [json_controls addObject:@{
                @"id": @(controls[i]),
                @"classFourCC": [NSString stringWithUTF8String:fourcc_string(class_id, class_fourcc)],
                @"className": [NSString stringWithUTF8String:coreaudio_class_name(class_id)],
                @"scopeFourCC": [NSString stringWithUTF8String:fourcc_string(scope, scope_fourcc)],
                @"scopeName": [NSString stringWithUTF8String:coreaudio_scope_name(scope)],
                @"element": @(element),
                @"name": json_value_for_cfstring(name),
                @"values": json_coreaudio_control_values(controls[i]),
            }];
        }
    }

    free(controls);
    return json_controls;
}

static NSDictionary *json_coreaudio_status(void) {
    AudioObjectID one = find_coreaudio_one();
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict setObject:json_bool(one != kAudioObjectUnknown) forKey:@"visible"];
    if (one == kAudioObjectUnknown) {
        [dict setObject:@"ONE not visible in this process; sandboxed processes may see an empty device list."
                 forKey:@"note"];
        return dict;
    }

    Float64 sample_rate = 0;
    UInt32 sample_rate_size = sizeof(sample_rate);
    bool has_sample_rate = coreaudio_get(one,
                                         kAudioDevicePropertyNominalSampleRate,
                                         kAudioObjectPropertyScopeGlobal,
                                         &sample_rate,
                                         &sample_rate_size);

    AudioObjectID default_input = coreaudio_default_device(kAudioHardwarePropertyDefaultInputDevice);
    AudioObjectID default_output = coreaudio_default_device(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectID default_system_output = coreaudio_default_device(kAudioHardwarePropertyDefaultSystemOutputDevice);

    [dict setObject:@(one) forKey:@"deviceId"];
    [dict setObject:json_value_for_cfstring(coreaudio_copy_string(one, kAudioObjectPropertyName)) forKey:@"name"];
    [dict setObject:json_value_for_cfstring(coreaudio_copy_string(one, kAudioObjectPropertyManufacturer))
             forKey:@"manufacturer"];
    [dict setObject:json_value_for_cfstring(coreaudio_copy_string(one, kAudioDevicePropertyDeviceUID)) forKey:@"uid"];
    if (has_sample_rate) {
        [dict setObject:@(sample_rate) forKey:@"nominalSampleRate"];
    }
    [dict setObject:@(coreaudio_channel_count(one, kAudioDevicePropertyScopeInput)) forKey:@"inputChannels"];
    [dict setObject:@(coreaudio_channel_count(one, kAudioDevicePropertyScopeOutput)) forKey:@"outputChannels"];
    [dict setObject:@{
        @"input": json_bool(one == default_input),
        @"output": json_bool(one == default_output),
        @"systemOutput": json_bool(one == default_system_output),
    } forKey:@"defaultRoles"];
    [dict setObject:@{
        @"global": json_bool(coreaudio_has_property(one,
                                                    kAudioDevicePropertyPlayThruVolumeDecibels,
                                                    kAudioObjectPropertyScopeGlobal)),
        @"input": json_bool(coreaudio_has_property(one,
                                                   kAudioDevicePropertyPlayThruVolumeDecibels,
                                                   kAudioDevicePropertyScopeInput)),
        @"output": json_bool(coreaudio_has_property(one,
                                            kAudioDevicePropertyPlayThruVolumeDecibels,
                                            kAudioDevicePropertyScopeOutput)),
    } forKey:@"playThroughVolumeDecibels"];
    [dict setObject:json_coreaudio_controls(one) forKey:@"controls"];
    return dict;
}

static NSDictionary *json_monitor_status(void) {
    uint16_t mix_value = (uint16_t)(((uint16_t)(kONELLMRemoteI2CControl & 0x3f) << 8) |
                                    kONELLMRemoteI2CAddress);
    return @{
        @"attenuationWrite": @{
            @"mapped": @YES,
            @"enabled": @NO,
            @"readback": @NO,
            @"bmRequestType": @0x40,
            @"bRequest": @(kONEVendorSetLLMOutputAttenuation),
            @"wIndex": @0,
            @"wValueTemplate": @"-attenuationDb",
            @"volumeDbRange": @[@-96, @0],
            @"audibleEffectConfirmed": @NO,
        },
        @"directInputMixWrite": @{
            @"mapped": @YES,
            @"enabled": @YES,
            @"dryRunOnly": @NO,
            @"readback": @NO,
            @"bmRequestType": @0x40,
            @"bRequest": @(kONEVendorRemoteI2CWrite),
            @"wValue": @(mix_value),
            @"wIndexTemplate": @"extMicLevel",
            @"wLength": @1,
            @"payloadTemplate": @"0x40 | instOrIntMicLevel",
            @"levelRange": @[@0, @63],
            @"volumeDbRange": @[@-63, @0],
            @"rawDirection": @"0 loud, 63 quiet",
        },
    };
}

static NSDictionary *json_output_status(IOUSBHostDevice *device) {
    return @{
        @"mainOutput": @{
            @"featureUnit": @(kOutputFeatureUnit),
            @"mute": json_mute_value(device, kOutputFeatureUnit),
            @"volume": json_volume_state(read_volume_state(device, kOutputFeatureUnit)),
        },
        @"headphone": @{
            @"featureUnit": @(kHeadphoneFeatureUnit),
            @"mute": json_mute_value(device, kHeadphoneFeatureUnit),
        },
    };
}

static NSDictionary *json_input_status(IOUSBHostDevice *device) {
    NSMutableDictionary *input = [NSMutableDictionary dictionary];
    [input setObject:@(kInputSelectorUnit) forKey:@"selectorUnit"];
    [input setObject:json_input_sources() forKey:@"sources"];

    const InputSource *source = NULL;
    uint8_t pin = 0;
    if (current_source(device, &source, &pin)) {
        [input setObject:json_input_source(source) forKey:@"currentSource"];
        [input setObject:json_volume_state(read_volume_state(device, source->feature_unit)) forKey:@"currentGain"];
    }

    return input;
}

static NSMutableDictionary *json_command_result(NSString *command,
                                                bool changed,
                                                bool dry_run,
                                                NSString *message) {
    return [@{
        @"ok": @YES,
        @"command": command,
        @"changed": json_bool(changed),
        @"dryRun": json_bool(dry_run),
        @"message": message,
    } mutableCopy];
}

static NSDictionary *json_status(IOUSBHostDevice *device) {
    NSMutableDictionary *uac = [NSMutableDictionary dictionary];
    NSDictionary *output = json_output_status(device);
    [uac setObject:output[@"mainOutput"] forKey:@"mainOutput"];
    [uac setObject:output[@"headphone"] forKey:@"headphone"];
    [uac setObject:json_input_status(device) forKey:@"input"];

    return @{
        @"device": @{
            @"vendorId": @(kApogeeVendorID),
            @"productId": @(kApogeeOneProductID),
            @"coreAudio": json_coreaudio_status(),
            @"uac": uac,
            @"monitor": json_monitor_status(),
        },
    };
}

static bool verify_u8_noop(IOUSBHostDevice *device,
                           const char *label,
                           uint8_t entity_id,
                           uint8_t control_selector) {
    uint8_t before = 0;
    uint8_t after = 0;
    if (!read_u8(device, kUACRequestGetCur, entity_id, control_selector, &before)) {
        printf("  %s: read failed\n", label);
        return false;
    }
    if (!write_u8(device, entity_id, control_selector, before)) {
        printf("  %s: write-current failed\n", label);
        return false;
    }
    if (!read_u8(device, kUACRequestGetCur, entity_id, control_selector, &after)) {
        printf("  %s: verify read failed\n", label);
        return false;
    }
    printf("  %s: %s (%u)\n", label, before == after ? "ok" : "mismatch", before);
    return before == after;
}

static bool verify_volume_noop(IOUSBHostDevice *device, const char *label, uint8_t entity_id) {
    VolumeState before = read_volume_state(device, entity_id);
    if (!before.has_current) {
        printf("  %s: read failed\n", label);
        return false;
    }
    if (!set_volume_fixed(device, entity_id, before.current)) {
        printf("  %s: write-current failed\n", label);
        return false;
    }
    VolumeState after = read_volume_state(device, entity_id);
    if (!after.has_current) {
        printf("  %s: verify read failed\n", label);
        return false;
    }
    printf("  %s: %s (%.2f dB)\n",
           label,
           before.current == after.current ? "ok" : "mismatch",
           fixed_db_to_double(before.current));
    return before.current == after.current;
}

static int command_self_test(IOUSBHostDevice *device) {
    puts("Apogee ONE no-op write self-test");
    puts("Writing each current value back to the same control, then reading it again.");

    bool ok = true;
    ok = verify_u8_noop(device, "main output mute", kOutputFeatureUnit, kUACFeatureMute) && ok;
    ok = verify_volume_noop(device, "main output volume", kOutputFeatureUnit) && ok;
    ok = verify_u8_noop(device, "headphone mute", kHeadphoneFeatureUnit, kUACFeatureMute) && ok;
    ok = verify_u8_noop(device, "input selector", kInputSelectorUnit, kUACSelectorControl) && ok;

    for (size_t i = 0; i < sizeof(kInputSources) / sizeof(kInputSources[0]); i++) {
        char label[80];
        snprintf(label,
                 sizeof(label),
                 "input gain pin %u feature %u",
                 kInputSources[i].pin,
                 kInputSources[i].feature_unit);
        ok = verify_volume_noop(device, label, kInputSources[i].feature_unit) && ok;
    }

    puts(ok ? "self-test: passed" : "self-test: failed");
    return ok ? 0 : 1;
}

static int command_status(IOUSBHostDevice *device, int argc, const char *argv[]) {
    bool json = false;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) {
            json = true;
        } else {
            fprintf(stderr, "Unknown status argument: %s\n", argv[i]);
            return 64;
        }
    }

    if (json) {
        return print_json_object(json_status(device));
    }

    puts("Apogee ONE status");
    print_coreaudio_status();
    puts("");

    print_mute_line(device, "main output", kOutputFeatureUnit);
    print_volume_line("main output volume", kOutputFeatureUnit, read_volume_state(device, kOutputFeatureUnit));
    print_mute_line(device, "headphone", kHeadphoneFeatureUnit);
    print_input_source(device);

    const InputSource *source = NULL;
    if (current_source(device, &source, NULL)) {
        print_volume_line("current input gain", source->feature_unit, read_volume_state(device, source->feature_unit));
    }

    puts("");
    print_monitor_discovery();
    return 0;
}

static int command_output(IOUSBHostDevice *device, int argc, const char *argv[]) {
    bool changed = false;
    bool json = false;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) {
            json = true;
        } else if (strcmp(argv[i], "--volume-db") == 0 && i + 1 < argc) {
            double db = 0;
            if (!parse_double_arg(argv[++i], &db)) {
                fprintf(stderr, "Invalid --volume-db value: %s\n", argv[i]);
                return 64;
            }
            if (!set_volume_db(device, kOutputFeatureUnit, db)) {
                return 1;
            }
            changed = true;
        } else if (strcmp(argv[i], "--mute") == 0 && i + 1 < argc) {
            uint8_t mute = 0;
            if (!parse_on_off(argv[++i], &mute)) {
                fprintf(stderr, "Invalid --mute value: %s\n", argv[i]);
                return 64;
            }
            if (!write_mute(device, kOutputFeatureUnit, mute)) {
                return 1;
            }
            changed = true;
        } else if (strcmp(argv[i], "--headphone-mute") == 0 && i + 1 < argc) {
            uint8_t mute = 0;
            if (!parse_on_off(argv[++i], &mute)) {
                fprintf(stderr, "Invalid --headphone-mute value: %s\n", argv[i]);
                return 64;
            }
            if (!write_mute(device, kHeadphoneFeatureUnit, mute)) {
                return 1;
            }
            changed = true;
        } else {
            fprintf(stderr, "Unknown output argument: %s\n", argv[i]);
            return 64;
        }
    }

    if (json) {
        NSMutableDictionary *result = json_command_result(@"output",
                                                          changed,
                                                          false,
                                                          changed ? @"Output updated" : @"Output status");
        [result setObject:json_output_status(device) forKey:@"output"];
        return print_json_object(result);
    }

    if (changed) {
        puts("output: updated");
    }
    print_mute_line(device, "main output", kOutputFeatureUnit);
    print_volume_line("main output volume", kOutputFeatureUnit, read_volume_state(device, kOutputFeatureUnit));
    print_mute_line(device, "headphone", kHeadphoneFeatureUnit);
    return 0;
}

static int command_input(IOUSBHostDevice *device, int argc, const char *argv[]) {
    const InputSource *selected_source = NULL;
    bool set_source = false;
    bool set_gain = false;
    bool json = false;
    double gain_db = 0;

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) {
            json = true;
        } else if (strcmp(argv[i], "--source") == 0 && i + 1 < argc) {
            if (!(selected_source = source_for_name(argv[++i]))) {
                fprintf(stderr, "Invalid --source value: %s\n", argv[i]);
                fputs("Valid sources: int-mic, ext-mic, ext-48v-mic, inst\n", stderr);
                return 64;
            }
            set_source = true;
        } else if (strcmp(argv[i], "--source-pin") == 0 && i + 1 < argc) {
            uint8_t pin = 0;
            if (!parse_u8_arg(argv[++i], &pin) || !(selected_source = source_for_pin(pin))) {
                fprintf(stderr, "Invalid --source-pin value: %s\n", argv[i]);
                return 64;
            }
            set_source = true;
        } else if (strcmp(argv[i], "--source-unit") == 0 && i + 1 < argc) {
            uint8_t unit = 0;
            if (!parse_u8_arg(argv[++i], &unit) || !(selected_source = source_for_feature_unit(unit))) {
                fprintf(stderr, "Invalid --source-unit value: %s\n", argv[i]);
                return 64;
            }
            set_source = true;
        } else if (strcmp(argv[i], "--gain-db") == 0 && i + 1 < argc) {
            if (!parse_double_arg(argv[++i], &gain_db)) {
                fprintf(stderr, "Invalid --gain-db value: %s\n", argv[i]);
                return 64;
            }
            set_gain = true;
        } else {
            fprintf(stderr, "Unknown input argument: %s\n", argv[i]);
            return 64;
        }
    }

    if (set_source && !set_input_source(device, selected_source)) {
        return 1;
    }

    if (set_gain) {
        const InputSource *gain_source = selected_source;
        if (!gain_source && !current_source(device, &gain_source, NULL)) {
            fputs("Cannot set input gain: current input source is unavailable.\n", stderr);
            return 1;
        }
        if (!set_volume_db(device, gain_source->feature_unit, gain_db)) {
            return 1;
        }
    }

    if (json) {
        NSMutableDictionary *result = json_command_result(@"input",
                                                          set_source || set_gain,
                                                          false,
                                                          (set_source || set_gain) ? @"Input updated" : @"Input status");
        [result setObject:json_input_status(device) forKey:@"input"];
        return print_json_object(result);
    }

    if (set_source || set_gain) {
        puts("input: updated");
    }
    print_input_source(device);
    const InputSource *source = NULL;
    if (current_source(device, &source, NULL)) {
        print_volume_line("current input gain", source->feature_unit, read_volume_state(device, source->feature_unit));
    }
    return 0;
}

static int command_monitor(IOUSBHostDevice *device, int argc, const char *argv[]) {
    bool set_mix_volume = false;
    bool set_legacy_attenuation = false;
    bool dry_run = false;
    bool mix_dry_run = false;
    bool mix_write = false;
    bool json = false;
    bool have_ext_mic_level = false;
    bool have_inst_int_level = false;
    double requested_volume_db = 0;
    double requested_attenuation_db = 0;
    double legacy_attenuation_db = 0;
    uint8_t mix_raw_level = 0;
    uint8_t ext_mic_level = 0;
    uint8_t inst_int_level = 0;

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) {
            json = true;
        } else if (strcmp(argv[i], "--attenuation-db") == 0 && i + 1 < argc) {
            if (set_mix_volume) {
                fputs("Use only one monitor level argument.\n", stderr);
                return 64;
            }
            double attenuation_db = 0;
            if (!parse_double_arg(argv[++i], &attenuation_db)) {
                fprintf(stderr, "Invalid --attenuation-db value: %s\n", argv[i]);
                return 64;
            }
            if (!monitor_mix_raw_from_attenuation_db(attenuation_db, &mix_raw_level)) {
                return 64;
            }
            requested_attenuation_db = attenuation_db;
            requested_volume_db = -attenuation_db;
            set_mix_volume = true;
        } else if (strcmp(argv[i], "--volume-db") == 0 && i + 1 < argc) {
            if (set_mix_volume) {
                fputs("Use only one monitor level argument.\n", stderr);
                return 64;
            }
            double volume_db = 0;
            if (!parse_double_arg(argv[++i], &volume_db)) {
                fprintf(stderr, "Invalid --volume-db value: %s\n", argv[i]);
                return 64;
            }
            if (!monitor_mix_raw_from_volume_db(volume_db, &mix_raw_level)) {
                return 64;
            }
            requested_volume_db = volume_db;
            requested_attenuation_db = -volume_db;
            set_mix_volume = true;
        } else if (strcmp(argv[i], "--legacy-attenuation-db") == 0 && i + 1 < argc) {
            if (set_legacy_attenuation) {
                fputs("Use only one legacy monitor attenuation argument.\n", stderr);
                return 64;
            }
            if (!parse_double_arg(argv[++i], &legacy_attenuation_db)) {
                fprintf(stderr, "Invalid --legacy-attenuation-db value: %s\n", argv[i]);
                return 64;
            }
            set_legacy_attenuation = true;
        } else if (strcmp(argv[i], "--legacy-volume-db") == 0 && i + 1 < argc) {
            if (set_legacy_attenuation) {
                fputs("Use only one legacy monitor attenuation argument.\n", stderr);
                return 64;
            }
            double volume_db = 0;
            if (!parse_double_arg(argv[++i], &volume_db)) {
                fprintf(stderr, "Invalid --legacy-volume-db value: %s\n", argv[i]);
                return 64;
            }
            if (volume_db < -96 || volume_db > 0) {
                fprintf(stderr, "Legacy monitor volume %.2f dB is outside range -96..0 dB.\n", volume_db);
                return 64;
            }
            legacy_attenuation_db = -volume_db;
            set_legacy_attenuation = true;
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            dry_run = true;
        } else if (strcmp(argv[i], "--mix-dry-run") == 0) {
            mix_dry_run = true;
        } else if (strcmp(argv[i], "--mix-levels") == 0) {
            mix_write = true;
        } else if (strcmp(argv[i], "--ext-mic-level") == 0 && i + 1 < argc) {
            if (!parse_u8_arg(argv[++i], &ext_mic_level) ||
                !validate_llm_mix_level("--ext-mic-level", ext_mic_level)) {
                return 64;
            }
            have_ext_mic_level = true;
        } else if (strcmp(argv[i], "--inst-int-level") == 0 && i + 1 < argc) {
            if (!parse_u8_arg(argv[++i], &inst_int_level) ||
                !validate_llm_mix_level("--inst-int-level", inst_int_level)) {
                return 64;
            }
            have_inst_int_level = true;
        } else {
            fprintf(stderr, "Unknown monitor argument: %s\n", argv[i]);
            return 64;
        }
    }

    if (mix_dry_run || mix_write || have_ext_mic_level || have_inst_int_level) {
        if (set_mix_volume || set_legacy_attenuation) {
            fputs("Use either monitor volume or raw monitor mix arguments, not both.\n", stderr);
            return 64;
        }
        if (mix_dry_run && mix_write) {
            fputs("Use either --mix-dry-run or --mix-levels, not both.\n", stderr);
            return 64;
        }
        if (dry_run && mix_write) {
            fputs("Use --mix-dry-run for monitor mix dry runs.\n", stderr);
            return 64;
        }
        if (!mix_dry_run && !mix_write) {
            fputs("Direct input monitor mix requires --mix-dry-run or --mix-levels.\n", stderr);
            return 64;
        }
        if (!have_ext_mic_level || !have_inst_int_level) {
            fputs("Monitor mix requires --ext-mic-level and --inst-int-level.\n", stderr);
            return 64;
        }

        if (mix_dry_run) {
            if (json) {
                NSMutableDictionary *result = json_command_result(@"monitor",
                                                                  false,
                                                                  true,
                                                                  @"Monitor mix dry run");
                [result setObject:@{
                    @"mode": @"directInputMixRaw",
                    @"extMicLevel": @(ext_mic_level),
                    @"instIntLevel": @(inst_int_level),
                    @"bRequest": @(kONEVendorRemoteI2CWrite),
                    @"readback": @NO,
                } forKey:@"monitor"];
                return print_json_object(result);
            }
            print_llm_mix_dry_run(ext_mic_level, inst_int_level);
            return 0;
        }

        if (!device) {
            fputs("Cannot send monitor mix request: USB device is not open.\n", stderr);
            return 1;
        }
        if (!set_llm_mix_levels(device, ext_mic_level, inst_int_level)) {
            return 1;
        }
        if (json) {
            NSMutableDictionary *result = json_command_result(@"monitor",
                                                              true,
                                                              false,
                                                              @"Monitor mix updated");
            [result setObject:@{
                @"mode": @"directInputMixRaw",
                @"extMicLevel": @(ext_mic_level),
                @"instIntLevel": @(inst_int_level),
                @"bRequest": @(kONEVendorRemoteI2CWrite),
                @"readback": @NO,
            } forKey:@"monitor"];
            return print_json_object(result);
        }
        printf("monitor: sent direct input monitor mix ext-mic=%u inst/int=%u (vendor request 0x%02x)\n",
               ext_mic_level,
               inst_int_level,
               kONEVendorRemoteI2CWrite);
        puts("monitor: no readback path is known yet; verify by listening or loopback measurement.");
        return 0;
    }

    if (set_mix_volume && set_legacy_attenuation) {
        fputs("Use either confirmed monitor volume or legacy monitor attenuation, not both.\n", stderr);
        return 64;
    }

    if (!set_mix_volume && !set_legacy_attenuation) {
        if (json) {
            NSMutableDictionary *result = json_command_result(@"monitor",
                                                              false,
                                                              false,
                                                              @"Monitor status");
            [result setObject:json_monitor_status() forKey:@"monitor"];
            return print_json_object(result);
        }
        print_monitor_discovery();
        return 0;
    }

    if (set_mix_volume) {
        if (dry_run && !device) {
            if (json) {
                NSMutableDictionary *result = json_command_result(@"monitor",
                                                                  false,
                                                                  true,
                                                                  @"Monitor volume dry run");
                [result setObject:@{
                    @"mode": @"directInputMix",
                    @"volumeDb": @(requested_volume_db),
                    @"attenuationDb": @(requested_attenuation_db),
                    @"rawLevel": @(mix_raw_level),
                    @"rawDirection": @"0 loud, 63 quiet",
                    @"readback": @NO,
                } forKey:@"monitor"];
                return print_json_object(result);
            }
            printf("monitor: dry run; would set current input direct-monitor raw attenuation %u (0=loud, 63=quiet)\n",
                   mix_raw_level);
            puts("monitor: open the device or use --mix-dry-run to see exact ext/inst request fields.");
            return 0;
        }

        if (!device) {
            fputs("Cannot send monitor volume request: USB device is not open.\n", stderr);
            return 1;
        }

        const InputSource *source = NULL;
        if (!current_source(device, &source, NULL)) {
            fputs("Cannot set monitor volume: current input source is unavailable.\n", stderr);
            return 1;
        }

        monitor_mix_levels_for_source(source, mix_raw_level, &ext_mic_level, &inst_int_level);
        if (dry_run) {
            if (json) {
                NSMutableDictionary *result = json_command_result(@"monitor",
                                                                  false,
                                                                  true,
                                                                  @"Monitor volume dry run");
                [result setObject:@{
                    @"mode": @"directInputMix",
                    @"source": json_input_source(source),
                    @"volumeDb": @(requested_volume_db),
                    @"attenuationDb": @(requested_attenuation_db),
                    @"rawLevel": @(mix_raw_level),
                    @"extMicLevel": @(ext_mic_level),
                    @"instIntLevel": @(inst_int_level),
                    @"rawDirection": @"0 loud, 63 quiet",
                    @"bRequest": @(kONEVendorRemoteI2CWrite),
                    @"readback": @NO,
                } forKey:@"monitor"];
                return print_json_object(result);
            }
            printf("monitor: current source %s; raw attenuation %u (0=loud, 63=quiet)\n",
                   source->cli_name,
                   mix_raw_level);
            print_llm_mix_dry_run(ext_mic_level, inst_int_level);
            return 0;
        }

        if (!set_llm_mix_levels(device, ext_mic_level, inst_int_level)) {
            return 1;
        }
        if (json) {
            NSMutableDictionary *result = json_command_result(@"monitor",
                                                              true,
                                                              false,
                                                              @"Monitor volume updated");
            [result setObject:@{
                @"mode": @"directInputMix",
                @"source": json_input_source(source),
                @"volumeDb": @(requested_volume_db),
                @"attenuationDb": @(requested_attenuation_db),
                @"rawLevel": @(mix_raw_level),
                @"extMicLevel": @(ext_mic_level),
                @"instIntLevel": @(inst_int_level),
                @"rawDirection": @"0 loud, 63 quiet",
                @"bRequest": @(kONEVendorRemoteI2CWrite),
                @"readback": @NO,
            } forKey:@"monitor"];
            return print_json_object(result);
        }
        printf("monitor: set %s direct-monitor volume raw=%u (ext-mic=%u inst/int=%u)\n",
               source->cli_name,
               mix_raw_level,
               ext_mic_level,
               inst_int_level);
        puts("monitor: raw values are inverted: 0 is loud, 63 is silent or near-silent.");
        return 0;
    }

    int rounded_attenuation = 0;
    int16_t request_value = 0;
    if (!monitor_attenuation_request_value(legacy_attenuation_db, &rounded_attenuation, &request_value)) {
        return 64;
    }

    if (dry_run) {
        if (json) {
            NSMutableDictionary *result = json_command_result(@"monitor",
                                                              false,
                                                              true,
                                                              @"Legacy monitor attenuation dry run");
            [result setObject:@{
                @"mode": @"legacyOutputAttenuation",
                @"attenuationDb": @(rounded_attenuation),
                @"volumeDb": @(-rounded_attenuation),
                @"bRequest": @(kONEVendorSetLLMOutputAttenuation),
                @"wValue": @(request_value),
                @"audibleEffectConfirmed": @NO,
                @"readback": @NO,
            } forKey:@"monitor"];
            return print_json_object(result);
        }
        printf("monitor: dry run; would send legacy low-latency output attenuation %d dB\n",
               rounded_attenuation);
        printf("monitor: vendor OUT request bmRequestType=0x40 bRequest=0x%02x wValue=%d wIndex=0 wLength=0\n",
               kONEVendorSetLLMOutputAttenuation,
               request_value);
        return 0;
    }

    if (!device) {
        fputs("Cannot send legacy monitor attenuation request: USB device is not open.\n", stderr);
        return 1;
    }

    if (!set_monitor_attenuation_db(device, legacy_attenuation_db, &rounded_attenuation, &request_value)) {
        return 1;
    }

    if (json) {
        NSMutableDictionary *result = json_command_result(@"monitor",
                                                          true,
                                                          false,
                                                          @"Legacy monitor attenuation sent");
        [result setObject:@{
            @"mode": @"legacyOutputAttenuation",
            @"attenuationDb": @(rounded_attenuation),
            @"volumeDb": @(-rounded_attenuation),
            @"bRequest": @(kONEVendorSetLLMOutputAttenuation),
            @"wValue": @(request_value),
            @"audibleEffectConfirmed": @NO,
            @"readback": @NO,
        } forKey:@"monitor"];
        return print_json_object(result);
    }

    printf("monitor: sent legacy low-latency output attenuation %d dB (vendor request 0x%02x wValue=%d)\n",
           rounded_attenuation,
           kONEVendorSetLLMOutputAttenuation,
           request_value);
    puts("monitor: no readback path is known yet; verify by listening or loopback measurement.");
    return 0;
}

static bool command_has_argument(int argc, const char *argv[], const char *argument) {
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], argument) == 0) {
            return true;
        }
    }
    return false;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2 || strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
            print_usage();
            return argc < 2 ? 64 : 0;
        }

        if (strcmp(argv[1], "monitor") == 0 &&
            (argc == 2 ||
             command_has_argument(argc, argv, "--dry-run") ||
             command_has_argument(argc, argv, "--mix-dry-run"))) {
            return command_monitor(nil, argc, argv);
        }

        IOUSBHostDevice *device = nil;
        if (!open_one_device(&device)) {
            return 1;
        }

        int result = 0;
        if (strcmp(argv[1], "status") == 0) {
            result = command_status(device, argc, argv);
        } else if (strcmp(argv[1], "output") == 0) {
            result = command_output(device, argc, argv);
        } else if (strcmp(argv[1], "input") == 0) {
            result = command_input(device, argc, argv);
        } else if (strcmp(argv[1], "monitor") == 0) {
            result = command_monitor(device, argc, argv);
        } else if (strcmp(argv[1], "self-test") == 0) {
            result = command_self_test(device);
        } else {
            fprintf(stderr, "Unknown command: %s\n", argv[1]);
            print_usage();
            result = 64;
        }

        [device destroy];
        return result;
    }
}
