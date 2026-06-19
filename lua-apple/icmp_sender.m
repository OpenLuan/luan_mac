//
//  icmp_sender.m — ICMP sender (CFStream + CFSocket on Apple)
//  LuanMac / OpenLuan (MIT)
//

#include <stdio.h>

#ifdef TARGET_OS_IPHONE
#import <Foundation/Foundation.h>
#define printf(fmt, ...) NSLog(@fmt, ##__VA_ARGS__)
#endif
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>
#endif

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

// Include luafan utilities for state management (resolved via HEADER_SEARCH_PATHS -> luafan/src)
#include "utlua.h"

// ICMP packet structure (following SimplePing format)
struct ICMPHeader {
    uint8_t     type;
    uint8_t     code;
    uint16_t    checksum;
    uint16_t    identifier;
    uint16_t    sequenceNumber;
    // data follows...
};

// IPv4 header structure for parsing received packets
struct IPv4Header {
    uint8_t     versionAndHeaderLength;
    uint8_t     differentiatedServices;
    uint16_t    totalLength;
    uint16_t    identification;
    uint16_t    flagsAndFragmentOffset;
    uint8_t     timeToLive;
    uint8_t     protocol;
    uint16_t    headerChecksum;
    uint8_t     sourceAddress[4];
    uint8_t     destinationAddress[4];
};

// ICMP sending context
struct icmp_context {
    // luafan state management - must be first
    lua_State *mainthread;
    int _ref_;

    // ICMP specific fields
    uint16_t identifier;
    uint16_t sequence;
    uint8_t ttl;                    // TTL value for traceroute
    struct timeval send_time;
    CFSocketRef socket_ref;
    CFRunLoopSourceRef source_ref;
    int use_coroutine;              // Whether to use coroutine yield/resume
};

// Calculate ICMP checksum (based on SimplePing implementation)
static uint16_t in_cksum(const void *buffer, size_t bufferLen) {
    size_t              bytesLeft;
    int32_t             sum;
    const uint16_t *    cursor;
    union {
        uint16_t        us;
        uint8_t         uc[2];
    } last;
    uint16_t            answer;

    bytesLeft = bufferLen;
    sum = 0;
    cursor = buffer;

    /*
     * Our algorithm is simple, using a 32 bit accumulator (sum), we add
     * sequential 16 bit words to it, and at the end, fold back all the
     * carry bits from the top 16 bits into the lower 16 bits.
     */
    while (bytesLeft > 1) {
        sum += *cursor;
        cursor += 1;
        bytesLeft -= 2;
    }

    /* mop up an odd byte, if necessary */
    if (bytesLeft == 1) {
        last.uc[0] = * (const uint8_t *) cursor;
        last.uc[1] = 0;
        sum += last.us;
    }

    /* add back carry outs from top 16 bits to low 16 bits */
    sum = (sum >> 16) + (sum & 0xffff);    /* add hi 16 to low 16 */
    sum += (sum >> 16);                    /* add carry */
    answer = (uint16_t) ~sum;              /* truncate to 16 bits */

    return answer;
}

// IPv4 header offset calculation (based on SimplePing)
static size_t icmp_header_offset_in_ipv4_packet(const void *packet, size_t packet_length) {
    size_t                  result;
    const struct IPv4Header *   ipPtr;
    size_t                      ipHeaderLength;

    result = 0;  // Return 0 if not found (instead of NSNotFound)
    if (packet_length >= (sizeof(struct IPv4Header) + sizeof(struct ICMPHeader))) {
        ipPtr = (const struct IPv4Header *) packet;
        if ( ((ipPtr->versionAndHeaderLength & 0xF0) == 0x40) &&            // IPv4
             ( ipPtr->protocol == IPPROTO_ICMP ) ) {
            ipHeaderLength = (ipPtr->versionAndHeaderLength & 0x0F) * sizeof(uint32_t);
            if (packet_length >= (ipHeaderLength + sizeof(struct ICMPHeader))) {
                result = ipHeaderLength;
            }
        }
    }
    return result;
}

#ifdef __APPLE__
// CFSocket callback for ICMP responses (based on SimplePing)
static void icmp_socket_callback(CFSocketRef socket, CFSocketCallBackType type,
                                CFDataRef address, const void *data, void *info) {
    struct icmp_context *ctx = (struct icmp_context *)info;
    // We only handle read callbacks (like SimplePing)
    if (type != kCFSocketReadCallBack) {
        return;
    }

    // Read data using recvfrom (like SimplePing)
    CFSocketNativeHandle native_socket = CFSocketGetNative(socket);
    if (native_socket == -1) {
        return;
    }

    struct sockaddr_storage addr;
    socklen_t addrLen = sizeof(addr);
    const size_t kBufferSize = 65535;  // Maximum IP packet size
    void *buffer = malloc(kBufferSize);

    if (!buffer) {
        return;
    }

    ssize_t bytesRead = recvfrom(native_socket, buffer, kBufferSize, 0,
                                (struct sockaddr *)&addr, &addrLen);

    if (bytesRead > 0) {
        // Find ICMP header offset (in case we received IPv4 header)
        size_t icmp_offset = icmp_header_offset_in_ipv4_packet(buffer, bytesRead);

        if (icmp_offset > 0 && (bytesRead - icmp_offset) >= sizeof(struct ICMPHeader)) {
            struct ICMPHeader *icmpPtr = (struct ICMPHeader *)((uint8_t *)buffer + icmp_offset);

            // Validate this is our Echo Reply
            if (icmpPtr->type == 0 &&  // Echo Reply
                ntohs(icmpPtr->identifier) == ctx->identifier &&
                ntohs(icmpPtr->sequenceNumber) == ctx->sequence) {

                // Calculate RTT
                struct timeval recv_time, rtt;
                gettimeofday(&recv_time, NULL);
                timersub(&recv_time, &ctx->send_time, &rtt);
                double rtt_ms = rtt.tv_sec * 1000.0 + rtt.tv_usec / 1000.0;

                // Parse IPv4 header
                const struct IPv4Header *ipPtr = (const struct IPv4Header *)buffer;

                // Parse ICMP header
                struct ICMPHeader *icmpPtr = (struct ICMPHeader *)((uint8_t *)buffer + icmp_offset);

                // Resume coroutine with success
                lua_State *L = NULL;
                REF_STATE_GET(ctx, L);

                if (L && ctx->use_coroutine) {
                    lua_pushboolean(L, 1);  // success
                    lua_pushnil(L);         // no error

                    // Create packet info table (all fields parsed from received buffer)
                    lua_newtable(L);

                    // Add basic response info
                    lua_pushnumber(L, rtt_ms);
                    lua_setfield(L, -2, "rtt");

                    // Add IP header info (parsed from received IPv4 header)
                    lua_newtable(L);
                    lua_pushnumber(L, (ipPtr->versionAndHeaderLength >> 4) & 0x0F);  // version
                    lua_setfield(L, -2, "version");
                    lua_pushnumber(L, (ipPtr->differentiatedServices >> 2) & 0x3F);  // DSCP
                    lua_setfield(L, -2, "dscp");
                    lua_pushnumber(L, ipPtr->differentiatedServices & 0x03);  // ECN
                    lua_setfield(L, -2, "ecn");
                    lua_pushnumber(L, ntohs(ipPtr->identification));
                    lua_setfield(L, -2, "identification");
                    lua_pushnumber(L, (ntohs(ipPtr->flagsAndFragmentOffset) >> 13) & 0x07);  // flags
                    lua_setfield(L, -2, "flag");
                    lua_pushnumber(L, ntohs(ipPtr->flagsAndFragmentOffset) & 0x1FFF);  // fragment offset
                    lua_setfield(L, -2, "fragmentoffset");
                    lua_pushnumber(L, ipPtr->timeToLive);  // TTL from received packet
                    lua_setfield(L, -2, "ttl");
                    lua_pushnumber(L, ipPtr->protocol);  // protocol from received packet
                    lua_setfield(L, -2, "protocol");
                    lua_setfield(L, -2, "ip");

                    // Add ICMP header info (parsed from received ICMP header)
                    lua_newtable(L);
                    lua_pushnumber(L, icmpPtr->type);  // type from received packet
                    lua_setfield(L, -2, "type");
                    lua_pushnumber(L, icmpPtr->code);  // code from received packet
                    lua_setfield(L, -2, "code");
                    lua_pushnumber(L, ntohs(icmpPtr->identifier));  // identifier from received packet
                    lua_setfield(L, -2, "identifier");
                    lua_pushnumber(L, ntohs(icmpPtr->sequenceNumber));  // sequence from received packet
                    lua_setfield(L, -2, "sequence_number");

                    // Extract ICMP body (data after ICMP header)
                    size_t icmp_data_len = bytesRead - icmp_offset - sizeof(struct ICMPHeader);
                    if (icmp_data_len > 0) {
                        const char *icmp_data = (const char *)((uint8_t *)buffer + icmp_offset + sizeof(struct ICMPHeader));
                        lua_pushlstring(L, icmp_data, icmp_data_len);
                    } else {
                        lua_pushstring(L, "");  // empty body
                    }
                    lua_setfield(L, -2, "body");
                    lua_setfield(L, -2, "icmp");

                    int result = FAN_RESUME(L, ctx->mainthread, 3);  // success, error, packet_info
                    if (result != LUA_OK && result != LUA_YIELD) {
                        const char *error = lua_tostring(L, -1);
                        lua_pop(L, 1);
                    }
                }
            }
        }
    }

    free(buffer);
}

// Create ICMP packet (based on SimplePing)
static NSData* create_icmp_packet(uint16_t identifier, uint16_t sequence, const char *data, size_t data_len) {
    size_t packet_len = sizeof(struct ICMPHeader) + data_len;
    NSMutableData *packet = [NSMutableData dataWithLength:packet_len];

    struct ICMPHeader *icmpPtr = (struct ICMPHeader *)packet.mutableBytes;
    icmpPtr->type = 8;  // Echo Request
    icmpPtr->code = 0;
    icmpPtr->checksum = 0;  // Will be calculated later
    icmpPtr->identifier = htons(identifier);
    icmpPtr->sequenceNumber = htons(sequence);

    // Copy payload data
    if (data && data_len > 0) {
        memcpy(&icmpPtr[1], data, data_len);
    }

    // Calculate checksum (IPv4 requires checksum)
    icmpPtr->checksum = in_cksum(packet.bytes, packet.length);

    return packet;
}

// Send ICMP packet using CFSocket (based on SimplePing approach)
static int send_icmp_packet_cfsocket(const char *dest_ip, uint16_t identifier,
                                   uint16_t sequence, const char *data, size_t data_len,
                                   uint8_t ttl, struct icmp_context *ctx) {
    // Create socket directly (like SimplePing)
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (fd < 0) {
        return -1;
    }

    // Set TTL if specified
    if (ttl > 0) {
        int ttl_val = (int)ttl;
        setsockopt(fd, IPPROTO_IP, IP_TTL, &ttl_val, sizeof(ttl_val));
    }

    // Create CFSocket from native socket (like SimplePing)
    CFSocketContext socket_context = {0, ctx, NULL, NULL, NULL};
    ctx->socket_ref = CFSocketCreateWithNative(kCFAllocatorDefault, fd,
                                             kCFSocketReadCallBack,
                                             icmp_socket_callback,
                                             &socket_context);

    if (!ctx->socket_ref) {
        close(fd);
        return -1;
    }

    // The socket will now take care of cleaning up our file descriptor
    assert(CFSocketGetSocketFlags(ctx->socket_ref) & kCFSocketCloseOnInvalidate);

    // Add to run loop
    ctx->source_ref = CFSocketCreateRunLoopSource(kCFAllocatorDefault, ctx->socket_ref, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), ctx->source_ref, kCFRunLoopDefaultMode);

    // Create destination address
    struct sockaddr_in dest_addr;
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = 0;

    if (inet_pton(AF_INET, dest_ip, &dest_addr.sin_addr) <= 0) {
        CFSocketInvalidate(ctx->socket_ref);
        CFRelease(ctx->socket_ref);
        ctx->socket_ref = NULL;
        return -1;
    }

    // Create ICMP packet
    NSData *packet = create_icmp_packet(identifier, sequence, data, data_len);

    // Send packet using sendto (like SimplePing)
    ssize_t bytesSent = sendto(fd, packet.bytes, packet.length, 0,
                              (struct sockaddr *)&dest_addr, sizeof(dest_addr));

    if (bytesSent < 0) {
        CFSocketInvalidate(ctx->socket_ref);
        CFRelease(ctx->socket_ref);
        ctx->socket_ref = NULL;
        return -1;
    }

    if (bytesSent != packet.length) {
        CFSocketInvalidate(ctx->socket_ref);
        CFRelease(ctx->socket_ref);
        ctx->socket_ref = NULL;
        return -1;
    }

    // Record send time
    gettimeofday(&ctx->send_time, NULL);

    return 0;  // Success
}
#endif



// Lua interface: send_ping(dest_ip, identifier, sequence, data, ttl) - yields
static int lua_send_icmp_ping(lua_State *L) {
    // Check arguments
    const char *dest_ip = luaL_checkstring(L, 1);
    lua_Integer identifier = luaL_checkinteger(L, 2);
    lua_Integer sequence = luaL_checkinteger(L, 3);

    size_t data_len = 0;
    const char *data = lua_tolstring(L, 4, &data_len);

    lua_Integer ttl = luaL_optinteger(L, 5, 64);
    if (ttl < 1 || ttl > 255) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "TTL must be between 1 and 255");
        return 2;
    }

    // Create context with coroutine support
    struct icmp_context *ctx = malloc(sizeof(struct icmp_context));
    if (!ctx) {
        return luaL_error(L, "Failed to allocate memory for ICMP context");
    }

    // Initialize for coroutine usage
    REF_STATE_SET(ctx, L);          // Set up state management for yield/resume
    ctx->use_coroutine = 1;         // Use coroutine yield/resume
    ctx->identifier = (uint16_t)identifier;
    ctx->sequence = (uint16_t)sequence;
    ctx->ttl = (uint8_t)ttl;
    ctx->socket_ref = NULL;
    ctx->source_ref = NULL;

#ifdef __APPLE__
    // Use CFSocket implementation on Apple platforms
    int result = send_icmp_packet_cfsocket(dest_ip, (uint16_t)identifier, (uint16_t)sequence,
                                         data, data_len, (uint8_t)ttl, ctx);

    if (result != 0) {
        // Failed to send
        free(ctx);
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Failed to send ICMP packet via CFSocket");
        return 2;
    }

    // Schedule cleanup after timeout (increased to 10 seconds)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        // Check if we still need to notify the Lua side about timeout
        lua_State *L = NULL;
        REF_STATE_GET(ctx, L);

        if (L && ctx->use_coroutine) {
            // Resume coroutine with timeout error
            lua_pushboolean(L, 0);  // success = false
            lua_pushstring(L, "ICMP request timeout");
            lua_pushnil(L);         // packet_info = nil

            int result = FAN_RESUME(L, ctx->mainthread, 3);  // success, error, packet_info
            if (result != LUA_OK && result != LUA_YIELD) {
                const char *error = lua_tostring(L, -1);
                lua_pop(L, 1);
            }
        }

        if (ctx->source_ref) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), ctx->source_ref, kCFRunLoopDefaultMode);
            CFRelease(ctx->source_ref);
        }
        if (ctx->socket_ref) {
            CFRelease(ctx->socket_ref);
        }
        // Clean up state reference for async function
        REF_STATE_CLEAR(ctx);
        free(ctx);
    });

    // Yield until response arrives
    return lua_yield(L, 0);

#else
    // Non-Apple platforms - return error
    free(ctx);
    lua_pushboolean(L, 0);
    lua_pushstring(L, "CFSocket ICMP with async only supported on Apple platforms");
    return 2;
#endif
}


// Lua module registration
static const struct luaL_Reg icmp_sender_functions[] = {
    {"send_ping", lua_send_icmp_ping},
    {NULL, NULL}
};

// Module initialization
int luaopen_icmp_sender(lua_State *L) {
    lua_newtable(L);
    luaL_setfuncs(L, icmp_sender_functions, 0);

    // Add version info
    lua_pushstring(L, "1.0.0");
    lua_setfield(L, -2, "version");

    lua_pushstring(L, "CFStream + CFSocket ICMP sender for iOS");
    lua_setfield(L, -2, "description");

    return 1;
}