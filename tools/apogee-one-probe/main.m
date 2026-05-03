#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#import <IOKit/usb/USBSpec.h>
#include <stdio.h>
#include <stdlib.h>

static uint16_t usb_to_host16(uint16_t value) {
    return CFSwapInt16LittleToHost(value);
}

static uint16_t read_le16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t read_le24(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16);
}

static void print_error(NSString *context, NSError *error) {
    if (error) {
        fprintf(stderr, "%s failed: %s (domain=%s code=%ld)\n",
                context.UTF8String,
                error.localizedDescription.UTF8String,
                error.domain.UTF8String,
                (long)error.code);
    } else {
        fprintf(stderr, "%s failed\n", context.UTF8String);
    }
}

static void print_request_error(const char *context, NSError *error) {
    if (error) {
        fprintf(stderr, "%s failed: %s (domain=%s code=%ld)\n",
                context,
                error.localizedDescription.UTF8String,
                error.domain.UTF8String,
                (long)error.code);
    } else {
        fprintf(stderr, "%s failed\n", context);
    }
}

static uint16_t read_uint16_property(io_service_t service, CFStringRef key) {
    uint16_t value = 0;
    CFTypeRef ref = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (ref && CFGetTypeID(ref) == CFNumberGetTypeID()) {
        int int_value = 0;
        if (CFNumberGetValue((CFNumberRef)ref, kCFNumberIntType, &int_value)) {
            value = (uint16_t)int_value;
        }
    }
    if (ref) {
        CFRelease(ref);
    }
    return value;
}

static char *copy_string_property(io_service_t service, CFStringRef key) {
    CFTypeRef ref = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!ref) {
        return NULL;
    }

    char *result = NULL;
    if (CFGetTypeID(ref) == CFStringGetTypeID()) {
        CFIndex length = CFStringGetLength((CFStringRef)ref);
        CFIndex max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
        result = calloc((size_t)max_size, 1);
        if (result && !CFStringGetCString((CFStringRef)ref, result, max_size, kCFStringEncodingUTF8)) {
            free(result);
            result = NULL;
        }
    }

    CFRelease(ref);
    return result;
}

static const char *audio_control_subtype_name(uint8_t subtype) {
    switch (subtype) {
        case 0x01: return "HEADER";
        case 0x02: return "INPUT_TERMINAL";
        case 0x03: return "OUTPUT_TERMINAL";
        case 0x04: return "MIXER_UNIT";
        case 0x05: return "SELECTOR_UNIT";
        case 0x06: return "FEATURE_UNIT";
        case 0x07: return "PROCESSING_UNIT";
        case 0x08: return "EXTENSION_UNIT";
        default: return "UNKNOWN_AC";
    }
}

static const char *audio_streaming_subtype_name(uint8_t subtype) {
    switch (subtype) {
        case 0x01: return "AS_GENERAL";
        case 0x02: return "FORMAT_TYPE";
        case 0x03: return "FORMAT_SPECIFIC";
        default: return "UNKNOWN_AS";
    }
}

static const char *audio_endpoint_subtype_name(uint8_t subtype) {
    switch (subtype) {
        case 0x01: return "EP_GENERAL";
        default: return "UNKNOWN_EP";
    }
}

static const char *terminal_type_name(uint16_t terminal_type) {
    switch (terminal_type) {
        case 0x0100: return "USB undefined";
        case 0x0101: return "USB streaming";
        case 0x0201: return "microphone";
        case 0x0202: return "desktop microphone";
        case 0x0203: return "personal microphone";
        case 0x0204: return "omni-directional microphone";
        case 0x0205: return "microphone array";
        case 0x0206: return "processing microphone array";
        case 0x0301: return "speaker";
        case 0x0302: return "headphones";
        case 0x0303: return "head mounted display audio";
        case 0x0304: return "desktop speaker";
        case 0x0305: return "room speaker";
        case 0x0306: return "communication speaker";
        case 0x0307: return "low frequency effects speaker";
        case 0x0601: return "analog connector";
        case 0x0602: return "digital audio interface";
        case 0x0603: return "line connector";
        case 0x0604: return "legacy audio connector";
        default: return "unknown";
    }
}

static const char *format_tag_name(uint16_t format_tag) {
    switch (format_tag) {
        case 0x0000: return "undefined";
        case 0x0001: return "PCM";
        case 0x0002: return "PCM8";
        case 0x0003: return "IEEE_FLOAT";
        case 0x1001: return "MPEG";
        case 0x1002: return "AC-3";
        default: return "unknown";
    }
}

static const char *endpoint_transfer_type(uint8_t attributes) {
    switch (attributes & 0x03) {
        case 0x00: return "control";
        case 0x01: return "isochronous";
        case 0x02: return "bulk";
        case 0x03: return "interrupt";
        default: return "unknown";
    }
}

static const char *endpoint_sync_type(uint8_t attributes) {
    switch ((attributes >> 2) & 0x03) {
        case 0x00: return "no sync";
        case 0x01: return "async";
        case 0x02: return "adaptive";
        case 0x03: return "sync";
        default: return "unknown";
    }
}

static uint32_t read_control_bitmap(const uint8_t *bytes, uint8_t size) {
    uint32_t value = 0;
    uint8_t capped_size = size > 4 ? 4 : size;
    for (uint8_t i = 0; i < capped_size; i++) {
        value |= ((uint32_t)bytes[i]) << (i * 8);
    }
    return value;
}

static void print_feature_control_names(uint32_t controls) {
    BOOL first = YES;
    const char *names[] = {
        "mute",
        "volume",
        "bass",
        "mid",
        "treble",
        "graphic-eq",
        "auto-gain",
        "delay",
        "bass-boost",
        "loudness"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (controls & (1u << i)) {
            printf("%s%s", first ? "" : ",", names[i]);
            first = NO;
        }
    }
    if (first) {
        printf("none");
    }
}

static void print_source_ids(const uint8_t *ids, uint8_t count) {
    printf("[");
    for (uint8_t i = 0; i < count; i++) {
        printf("%s%u", i == 0 ? "" : ",", ids[i]);
    }
    printf("]");
}

static void dump_audio_control_descriptor(const uint8_t *descriptor, uint8_t length) {
    uint8_t subtype = length >= 3 ? descriptor[2] : 0xff;
    printf("    cs audio-control %s subtype=0x%02x length=%u",
           audio_control_subtype_name(subtype),
           subtype,
           length);

    switch (subtype) {
        case 0x01:
            if (length >= 8) {
                uint8_t collection_count = descriptor[7];
                printf(": adc=0x%04x totalLength=%u interfaces=",
                       read_le16(&descriptor[3]),
                       read_le16(&descriptor[5]));
                print_source_ids(&descriptor[8], (uint8_t)MIN(collection_count, length > 8 ? length - 8 : 0));
            }
            break;
        case 0x02:
            if (length >= 12) {
                uint16_t terminal_type = read_le16(&descriptor[4]);
                printf(": id=%u type=0x%04x(%s) assoc=%u channels=%u channelConfig=0x%04x",
                       descriptor[3],
                       terminal_type,
                       terminal_type_name(terminal_type),
                       descriptor[6],
                       descriptor[7],
                       read_le16(&descriptor[8]));
            }
            break;
        case 0x03:
            if (length >= 9) {
                uint16_t terminal_type = read_le16(&descriptor[4]);
                printf(": id=%u type=0x%04x(%s) assoc=%u source=%u",
                       descriptor[3],
                       terminal_type,
                       terminal_type_name(terminal_type),
                       descriptor[6],
                       descriptor[7]);
            }
            break;
        case 0x04:
            if (length >= 8) {
                uint8_t pin_count = descriptor[4];
                printf(": id=%u pins=%u sources=", descriptor[3], pin_count);
                print_source_ids(&descriptor[5], (uint8_t)MIN(pin_count, length > 5 ? length - 5 : 0));
                size_t channel_offset = 5 + pin_count;
                if (channel_offset + 4 <= length) {
                    printf(" channels=%u channelConfig=0x%04x",
                           descriptor[channel_offset],
                           read_le16(&descriptor[channel_offset + 1]));
                }
            }
            break;
        case 0x05:
            if (length >= 7) {
                uint8_t pin_count = descriptor[4];
                printf(": id=%u pins=%u sources=", descriptor[3], pin_count);
                print_source_ids(&descriptor[5], (uint8_t)MIN(pin_count, length > 5 ? length - 5 : 0));
            }
            break;
        case 0x06:
            if (length >= 7) {
                uint8_t control_size = descriptor[5];
                int control_count = control_size == 0 ? 0 : (length - 7) / control_size;
                printf(": id=%u source=%u controlSize=%u controls=%d",
                       descriptor[3],
                       descriptor[4],
                       control_size,
                       control_count);
                for (int i = 0; i < control_count; i++) {
                    const uint8_t *control = &descriptor[6 + (i * control_size)];
                    uint32_t bitmap = read_control_bitmap(control, control_size);
                    printf(" %s=0x%0*x(",
                           i == 0 ? "master" : "ch",
                           control_size * 2,
                           bitmap);
                    print_feature_control_names(bitmap);
                    printf(")");
                }
            }
            break;
        case 0x08:
            if (length >= 13) {
                uint8_t pin_count = descriptor[6];
                printf(": id=%u code=0x%04x pins=%u sources=",
                       descriptor[3],
                       read_le16(&descriptor[4]),
                       pin_count);
                print_source_ids(&descriptor[7], (uint8_t)MIN(pin_count, length > 7 ? length - 7 : 0));
            }
            break;
        default:
            break;
    }

    printf("\n");
}

static void dump_audio_streaming_descriptor(const uint8_t *descriptor, uint8_t length) {
    uint8_t subtype = length >= 3 ? descriptor[2] : 0xff;
    printf("    cs audio-streaming %s subtype=0x%02x length=%u",
           audio_streaming_subtype_name(subtype),
           subtype,
           length);

    switch (subtype) {
        case 0x01:
            if (length >= 7) {
                uint16_t format_tag = read_le16(&descriptor[5]);
                printf(": terminalLink=%u delay=%u format=0x%04x(%s)",
                       descriptor[3],
                       descriptor[4],
                       format_tag,
                       format_tag_name(format_tag));
            }
            break;
        case 0x02:
            if (length >= 8) {
                uint8_t freq_type = descriptor[7];
                printf(": formatType=%u channels=%u subframeBytes=%u bitResolution=%u frequencies=",
                       descriptor[3],
                       descriptor[4],
                       descriptor[5],
                       descriptor[6]);
                if (freq_type == 0) {
                    if (length >= 14) {
                        printf("%u-%u", read_le24(&descriptor[8]), read_le24(&descriptor[11]));
                    } else {
                        printf("continuous");
                    }
                } else {
                    printf("[");
                    for (uint8_t i = 0; i < freq_type && (8 + (i * 3) + 2) < length; i++) {
                        printf("%s%u", i == 0 ? "" : ",", read_le24(&descriptor[8 + (i * 3)]));
                    }
                    printf("]");
                }
            }
            break;
        default:
            break;
    }

    printf("\n");
}

static void dump_audio_endpoint_descriptor(const uint8_t *descriptor, uint8_t length) {
    uint8_t subtype = length >= 3 ? descriptor[2] : 0xff;
    printf("    cs endpoint %s subtype=0x%02x length=%u",
           audio_endpoint_subtype_name(subtype),
           subtype,
           length);

    if (subtype == 0x01 && length >= 7) {
        printf(": attributes=0x%02x lockDelayUnits=%u lockDelay=%u",
               descriptor[3],
               descriptor[4],
               read_le16(&descriptor[5]));
    }

    printf("\n");
}

static void dump_configuration(const IOUSBConfigurationDescriptor *config, NSUInteger length) {
    if (!config) {
        puts("Configuration: unavailable");
        return;
    }

    uint16_t total = usb_to_host16(config->wTotalLength);
    if (length > 0 && length < total) {
        total = (uint16_t)length;
    }

    printf("Configuration:\n");
    printf("  value: %u\n", config->bConfigurationValue);
    printf("  interfaces: %u\n", config->bNumInterfaces);
    printf("  attributes: 0x%02x\n", config->bmAttributes);
    printf("  maxPower: %u mA\n", config->MaxPower * 2);
    printf("  totalLength: %u\n", usb_to_host16(config->wTotalLength));

    const uint8_t *cursor = (const uint8_t *)config;
    uint16_t offset = 0;
    int current_interface = -1;
    uint8_t current_interface_subclass = 0;
    uint8_t seen_interfaces[256] = {0};

    while (offset + 2 <= total) {
        uint8_t descriptor_length = cursor[offset];
        uint8_t descriptor_type = cursor[offset + 1];
        if (descriptor_length == 0 || offset + descriptor_length > total) {
            printf("  descriptor parse stopped at offset %u (length=%u type=0x%02x)\n",
                   offset,
                   descriptor_length,
                   descriptor_type);
            break;
        }

        if (descriptor_type == kUSBInterfaceDesc) {
            const IOUSBInterfaceDescriptor *iface = (const IOUSBInterfaceDescriptor *)&cursor[offset];
            current_interface = iface->bInterfaceNumber;
            current_interface_subclass = iface->bInterfaceSubClass;
            seen_interfaces[iface->bInterfaceNumber] = 1;
            printf("  interface %u alt %u: class=0x%02x subclass=0x%02x protocol=0x%02x endpoints=%u\n",
                   iface->bInterfaceNumber,
                   iface->bAlternateSetting,
                   iface->bInterfaceClass,
                   iface->bInterfaceSubClass,
                   iface->bInterfaceProtocol,
                   iface->bNumEndpoints);
        } else if (descriptor_type == kUSBEndpointDesc) {
            const IOUSBEndpointDescriptor *endpoint = (const IOUSBEndpointDescriptor *)&cursor[offset];
            printf("    endpoint interface=%d address=0x%02x attributes=0x%02x maxPacket=%u interval=%u\n",
                   current_interface,
                   endpoint->bEndpointAddress,
                   endpoint->bmAttributes,
                   usb_to_host16(endpoint->wMaxPacketSize),
                   endpoint->bInterval);
            printf("      transfer=%s sync=%s\n",
                   endpoint_transfer_type(endpoint->bmAttributes),
                   endpoint_sync_type(endpoint->bmAttributes));
        } else if (descriptor_type == 0x24 && current_interface_subclass == kUSBAudioControlSubClass) {
            dump_audio_control_descriptor(&cursor[offset], descriptor_length);
        } else if (descriptor_type == 0x24 && current_interface_subclass == kUSBAudioStreamingSubClass) {
            dump_audio_streaming_descriptor(&cursor[offset], descriptor_length);
        } else if (descriptor_type == 0x25) {
            dump_audio_endpoint_descriptor(&cursor[offset], descriptor_length);
        } else {
            printf("    descriptor offset=%u type=0x%02x length=%u\n",
                   offset,
                   descriptor_type,
                   descriptor_length);
        }

        offset += descriptor_length;
    }

    unsigned int unique_interface_count = 0;
    for (size_t i = 0; i < sizeof(seen_interfaces); i++) {
        if (seen_interfaces[i]) {
            unique_interface_count++;
        }
    }
    if (unique_interface_count != config->bNumInterfaces) {
        printf("  warning: descriptor contains %u unique interface numbers, configuration advertises %u\n",
               unique_interface_count,
               config->bNumInterfaces);
    }
}

static BOOL read_uac_control(IOUSBHostDevice *device,
                             uint8_t request,
                             uint8_t entity_id,
                             uint8_t control_selector,
                             uint8_t channel,
                             uint8_t interface_number,
                             NSMutableData *data,
                             NSUInteger *bytes_transferred) {
    IOUSBDeviceRequest usb_request = {
        .bmRequestType = IOUSBHostDeviceRequestType(kIOUSBDeviceRequestDirectionValueIn,
                                                    kIOUSBDeviceRequestTypeValueClass,
                                                    kIOUSBDeviceRequestRecipientValueInterface),
        .bRequest = request,
        .wValue = (uint16_t)(((uint16_t)control_selector << 8) | channel),
        .wIndex = (uint16_t)(((uint16_t)entity_id << 8) | interface_number),
        .wLength = (uint16_t)data.length
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
                 "GET request=0x%02x entity=%u control=%u channel=%u",
                 request,
                 entity_id,
                 control_selector,
                 channel);
        print_request_error(context, error);
    }
    return ok;
}

static BOOL read_uac_u8(IOUSBHostDevice *device,
                        uint8_t request,
                        uint8_t entity_id,
                        uint8_t control_selector,
                        uint8_t channel,
                        uint8_t interface_number,
                        uint8_t *value) {
    NSMutableData *data = [NSMutableData dataWithLength:1];
    NSUInteger bytes = 0;
    if (!read_uac_control(device,
                          request,
                          entity_id,
                          control_selector,
                          channel,
                          interface_number,
                          data,
                          &bytes) || bytes < 1) {
        return NO;
    }
    *value = ((const uint8_t *)data.bytes)[0];
    return YES;
}

static BOOL read_uac_s16(IOUSBHostDevice *device,
                         uint8_t request,
                         uint8_t entity_id,
                         uint8_t control_selector,
                         uint8_t channel,
                         uint8_t interface_number,
                         int16_t *value) {
    NSMutableData *data = [NSMutableData dataWithLength:2];
    NSUInteger bytes = 0;
    if (!read_uac_control(device,
                          request,
                          entity_id,
                          control_selector,
                          channel,
                          interface_number,
                          data,
                          &bytes) || bytes < 2) {
        return NO;
    }
    *value = (int16_t)read_le16((const uint8_t *)data.bytes);
    return YES;
}

static void dump_volume_control(IOUSBHostDevice *device, const char *label, uint8_t entity_id) {
    const uint8_t interface_number = 0;
    const uint8_t channel_master = 0;
    const uint8_t volume_control = 0x02;
    const uint8_t get_cur = 0x81;
    const uint8_t get_min = 0x82;
    const uint8_t get_max = 0x83;
    const uint8_t get_res = 0x84;

    int16_t cur = 0;
    int16_t min = 0;
    int16_t max = 0;
    int16_t res = 0;
    BOOL has_cur = read_uac_s16(device, get_cur, entity_id, volume_control, channel_master, interface_number, &cur);
    BOOL has_min = read_uac_s16(device, get_min, entity_id, volume_control, channel_master, interface_number, &min);
    BOOL has_max = read_uac_s16(device, get_max, entity_id, volume_control, channel_master, interface_number, &max);
    BOOL has_res = read_uac_s16(device, get_res, entity_id, volume_control, channel_master, interface_number, &res);

    printf("  feature %u %s volume:", entity_id, label);
    if (has_cur) {
        printf(" cur=%.2f dB", cur / 256.0);
    } else {
        printf(" cur=unavailable");
    }
    if (has_min && has_max) {
        printf(" range=%.2f..%.2f dB", min / 256.0, max / 256.0);
    }
    if (has_res) {
        printf(" step=%.2f dB", res / 256.0);
    }
    printf("\n");
}

static void dump_mute_control(IOUSBHostDevice *device, const char *label, uint8_t entity_id) {
    const uint8_t interface_number = 0;
    const uint8_t channel_master = 0;
    const uint8_t mute_control = 0x01;
    const uint8_t get_cur = 0x81;

    uint8_t cur = 0;
    BOOL has_cur = read_uac_u8(device, get_cur, entity_id, mute_control, channel_master, interface_number, &cur);
    printf("  feature %u %s mute: %s\n", entity_id, label, has_cur ? (cur ? "on" : "off") : "unavailable");
}

static void dump_selector_control(IOUSBHostDevice *device) {
    const uint8_t interface_number = 0;
    const uint8_t selector_entity = 7;
    const uint8_t selector_control = 0x01;
    const uint8_t channel_master = 0;
    const uint8_t get_cur = 0x81;

    uint8_t cur = 0;
    BOOL has_cur = read_uac_u8(device,
                               get_cur,
                               selector_entity,
                               selector_control,
                               channel_master,
                               interface_number,
                               &cur);
    printf("  selector 7 input source: ");
    if (has_cur) {
        const char *source = "unknown";
        switch (cur) {
            case 1: source = "source unit 5"; break;
            case 2: source = "source unit 11"; break;
            case 3: source = "source unit 13"; break;
            case 4: source = "source unit 9"; break;
            default: break;
        }
        printf("pin=%u (%s)\n", cur, source);
    } else {
        printf("unavailable\n");
    }
}

static void dump_uac_controls(IOUSBHostDevice *device) {
    puts("USB Audio Class control values:");
    dump_selector_control(device);
    dump_mute_control(device, "main speaker path", 2);
    dump_volume_control(device, "main speaker path", 2);
    dump_mute_control(device, "headphone path", 22);
    dump_volume_control(device, "input source 5", 5);
    dump_volume_control(device, "input source 9", 9);
    dump_volume_control(device, "input source 11", 11);
    dump_volume_control(device, "input source 13", 13);
}

static void print_device_summary(io_service_t service) {
    uint16_t vendor = read_uint16_property(service, CFSTR("idVendor"));
    uint16_t product = read_uint16_property(service, CFSTR("idProduct"));
    uint16_t release = read_uint16_property(service, CFSTR("bcdDevice"));
    char *vendor_name = copy_string_property(service, CFSTR("USB Vendor Name"));
    char *product_name = copy_string_property(service, CFSTR("USB Product Name"));

    printf("Device:\n");
    printf("  vendor: 0x%04x%s%s\n", vendor, vendor_name ? " " : "", vendor_name ? vendor_name : "");
    printf("  product: 0x%04x%s%s\n", product, product_name ? " " : "", product_name ? product_name : "");
    printf("  release: 0x%04x\n", release);

    free(vendor_name);
    free(product_name);
}

static int probe_host_device(io_service_t service, BOOL configure, BOOL read_controls) {
    print_device_summary(service);

    NSError *error = nil;
    dispatch_queue_t queue = dispatch_queue_create("one-probe.usb", DISPATCH_QUEUE_SERIAL);
    IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:service
                                                                 options:IOUSBHostObjectInitOptionsNone
                                                                   queue:queue
                                                                   error:&error
                                                         interestHandler:nil];
    if (!device) {
        print_error(@"IOUSBHostDevice init", error);
        error = nil;
        device = [[IOUSBHostDevice alloc] initWithIOService:service
                                                    options:IOUSBHostObjectInitOptionsDeviceSeize
                                                      queue:queue
                                                      error:&error
                                            interestHandler:nil];
        if (!device) {
            print_error(@"IOUSBHostDevice init with DeviceSeize", error);
            return 1;
        }
    }

    const IOUSBConfigurationDescriptor *selected = device.configurationDescriptor;
    if (selected) {
        dump_configuration(selected, usb_to_host16(selected->wTotalLength));
    } else {
        puts("Selected configuration: unavailable from cache");
    }

    NSUInteger length = 4096;
    error = nil;
    const IOUSBDescriptor *descriptor = [device descriptorWithType:kUSBConfDesc
                                                           length:&length
                                                            index:0
                                                       languageID:0
                                                      requestType:kIOUSBDeviceRequestTypeValueStandard
                                                 requestRecipient:kIOUSBDeviceRequestRecipientValueDevice
                                                            error:&error];
    if (descriptor) {
        printf("Fetched configuration descriptor length: %lu\n", (unsigned long)length);
        dump_configuration((const IOUSBConfigurationDescriptor *)descriptor, length);
    } else {
        print_error(@"descriptorWithType(kUSBConfDesc)", error);
    }

    if (configure) {
        error = nil;
        puts("Sending SET_CONFIGURATION 1 with interface matching enabled...");
        if (![device configureWithValue:1 matchInterfaces:YES error:&error]) {
            print_error(@"configureWithValue(1, matchInterfaces:YES)", error);
            [device destroy];
            return 1;
        }
        puts("SET_CONFIGURATION completed.");
    }

    if (read_controls) {
        dump_uac_controls(device);
    }

    [device destroy];
    return descriptor ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL configure = NO;
        BOOL read_controls = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--configure") == 0) {
                configure = YES;
            } else if (strcmp(argv[i], "--read-controls") == 0) {
                read_controls = YES;
            } else {
                fprintf(stderr, "Unknown argument: %s\n", argv[i]);
                return 64;
            }
        }

        CFMutableDictionaryRef matching = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(0x0c60)
                                                                                      productID:@(0x0003)
                                                                                      bcdDevice:nil
                                                                                    deviceClass:nil
                                                                                 deviceSubclass:nil
                                                                                 deviceProtocol:nil
                                                                                          speed:nil
                                                                                 productIDArray:nil];
        if (!matching) {
            fputs("Could not create IOUSBHostDevice matching dictionary.\n", stderr);
            return 1;
        }

        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
        if (service == IO_OBJECT_NULL) {
            fputs("Apogee ONE USB device 0x0c60:0x0003 was not found.\n", stderr);
            return 2;
        }

        puts("Matched provider class: IOUSBHostDevice");
        int result = probe_host_device(service, configure, read_controls);
        IOObjectRelease(service);
        return result;
    }
}
