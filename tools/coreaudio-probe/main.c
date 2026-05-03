#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

static bool get_property_size(AudioObjectID object_id,
                              AudioObjectPropertySelector selector,
                              AudioObjectPropertyScope scope,
                              UInt32 *size) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };

    if (!AudioObjectHasProperty(object_id, &address)) {
        return false;
    }

    return AudioObjectGetPropertyDataSize(object_id, &address, 0, NULL, size) == noErr;
}

static bool get_property(AudioObjectID object_id,
                         AudioObjectPropertySelector selector,
                         AudioObjectPropertyScope scope,
                         void *data,
                         UInt32 *size) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };

    if (!AudioObjectHasProperty(object_id, &address)) {
        return false;
    }

    return AudioObjectGetPropertyData(object_id, &address, 0, NULL, size, data) == noErr;
}

static AudioObjectID get_audio_object_id(AudioObjectID object_id,
                                         AudioObjectPropertySelector selector) {
    AudioObjectID value = kAudioObjectUnknown;
    UInt32 size = sizeof(value);
    if (!get_property(object_id, selector, kAudioObjectPropertyScopeGlobal, &value, &size)) {
        return kAudioObjectUnknown;
    }
    return value;
}

static UInt32 get_uint32(AudioObjectID object_id, AudioObjectPropertySelector selector) {
    UInt32 value = 0;
    UInt32 size = sizeof(value);
    if (!get_property(object_id, selector, kAudioObjectPropertyScopeGlobal, &value, &size)) {
        return 0;
    }
    return value;
}

static Float64 get_float64(AudioObjectID object_id, AudioObjectPropertySelector selector) {
    Float64 value = 0;
    UInt32 size = sizeof(value);
    if (!get_property(object_id, selector, kAudioObjectPropertyScopeGlobal, &value, &size)) {
        return 0;
    }
    return value;
}

static CFStringRef copy_string_property(AudioObjectID object_id,
                                        AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (!get_property(object_id, selector, kAudioObjectPropertyScopeGlobal, &value, &size)) {
        return NULL;
    }
    return value;
}

static void print_cf_string(CFStringRef string) {
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

static void print_fourcc(UInt32 value) {
    char chars[5] = {
        (char)((value >> 24) & 0xff),
        (char)((value >> 16) & 0xff),
        (char)((value >> 8) & 0xff),
        (char)(value & 0xff),
        0,
    };

    for (int i = 0; i < 4; i++) {
        if (chars[i] < 32 || chars[i] > 126) {
            chars[i] = '.';
        }
    }
    printf("%s", chars);
}

static UInt32 channel_count(AudioObjectID device_id, AudioObjectPropertyScope scope) {
    UInt32 size = 0;
    if (!get_property_size(device_id, kAudioDevicePropertyStreamConfiguration, scope, &size) ||
        size < sizeof(AudioBufferList)) {
        return 0;
    }

    AudioBufferList *buffer_list = calloc(1, size);
    if (!buffer_list) {
        return 0;
    }

    UInt32 channels = 0;
    if (get_property(device_id, kAudioDevicePropertyStreamConfiguration, scope, buffer_list, &size)) {
        for (UInt32 i = 0; i < buffer_list->mNumberBuffers; i++) {
            channels += buffer_list->mBuffers[i].mNumberChannels;
        }
    }

    free(buffer_list);
    return channels;
}

static void print_device(AudioObjectID device_id,
                         AudioObjectID default_input,
                         AudioObjectID default_output,
                         AudioObjectID default_system_output) {
    CFStringRef name = copy_string_property(device_id, kAudioObjectPropertyName);
    CFStringRef manufacturer = copy_string_property(device_id, kAudioObjectPropertyManufacturer);
    CFStringRef uid = copy_string_property(device_id, kAudioDevicePropertyDeviceUID);
    UInt32 transport = get_uint32(device_id, kAudioDevicePropertyTransportType);
    UInt32 alive = get_uint32(device_id, kAudioDevicePropertyDeviceIsAlive);
    Float64 sample_rate = get_float64(device_id, kAudioDevicePropertyNominalSampleRate);
    UInt32 input_channels = channel_count(device_id, kAudioDevicePropertyScopeInput);
    UInt32 output_channels = channel_count(device_id, kAudioDevicePropertyScopeOutput);

    printf("Device %u", device_id);
    if (device_id == default_input) {
        printf(" [default input]");
    }
    if (device_id == default_output) {
        printf(" [default output]");
    }
    if (device_id == default_system_output) {
        printf(" [default system output]");
    }
    printf("\n");

    printf("  name: ");
    print_cf_string(name);
    printf("\n");

    printf("  manufacturer: ");
    print_cf_string(manufacturer);
    printf("\n");

    printf("  uid: ");
    print_cf_string(uid);
    printf("\n");

    printf("  transport: ");
    print_fourcc(transport);
    printf("\n");

    printf("  alive: %s\n", alive ? "yes" : "no");
    printf("  nominal sample rate: %.0f\n", sample_rate);
    printf("  channels: input=%u output=%u\n", input_channels, output_channels);

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

int main(void) {
    UInt32 size = 0;
    if (!get_property_size(kAudioObjectSystemObject,
                           kAudioHardwarePropertyDevices,
                           kAudioObjectPropertyScopeGlobal,
                           &size) ||
        size == 0) {
        fputs("No Core Audio devices returned by kAudioHardwarePropertyDevices.\n", stderr);
        return 1;
    }

    AudioObjectID *devices = calloc(1, size);
    if (!devices) {
        fputs("Could not allocate device list.\n", stderr);
        return 1;
    }

    if (!get_property(kAudioObjectSystemObject,
                      kAudioHardwarePropertyDevices,
                      kAudioObjectPropertyScopeGlobal,
                      devices,
                      &size)) {
        fputs("Could not read Core Audio device list.\n", stderr);
        free(devices);
        return 1;
    }

    AudioObjectID default_input = get_audio_object_id(kAudioObjectSystemObject,
                                                     kAudioHardwarePropertyDefaultInputDevice);
    AudioObjectID default_output = get_audio_object_id(kAudioObjectSystemObject,
                                                      kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectID default_system_output = get_audio_object_id(kAudioObjectSystemObject,
                                                             kAudioHardwarePropertyDefaultSystemOutputDevice);
    UInt32 count = size / sizeof(AudioObjectID);

    printf("Core Audio devices: %u\n", count);
    printf("Default input id: %u\n", default_input);
    printf("Default output id: %u\n", default_output);
    printf("Default system output id: %u\n\n", default_system_output);

    for (UInt32 i = 0; i < count; i++) {
        print_device(devices[i], default_input, default_output, default_system_output);
        printf("\n");
    }

    free(devices);
    return 0;
}
