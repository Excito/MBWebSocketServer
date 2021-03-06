// Originally created by Max Howell in October 2011.
// This class is in the public domain.

#import <CommonCrypto/CommonDigest.h>
#import "MBWebSocketServer.h"

@interface MBWebSocketServer () <GCDAsyncSocketDelegate>
@end

@interface NSString (MBWebSocketServer)
- (id)sha1base64;
@end

static unsigned long long ntohll(unsigned long long v) {
    union { unsigned long lv[2]; unsigned long long llv; } u;
    u.llv = v;
    return ((unsigned long long)ntohl(u.lv[0]) << 32) | (unsigned long long)ntohl(u.lv[1]);
}



@implementation MBWebSocketServer
@dynamic connected;
@dynamic clientCount;

- (id)initWithPort:(NSUInteger)port delegate:(id<MBWebSocketServerDelegate>)delegate {
    _port = port;
    _delegate = delegate;
    socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
    connections = [NSMutableArray new];

    NSError *error = nil;
    [socket acceptOnPort:_port error:&error];

    if (error) {
        NSLog(@"MBWebSockerServer failed to initialize: %@", error);
        return nil;
    }

    return self;
}

- (BOOL)connected {
    return connections.count > 0;
}

- (NSUInteger)clientCount {
    return connections.count;
}

- (void)send:(id)object {
    id payload = [object webSocketFrameData];
    for (GCDAsyncSocket *connection in connections)
        [connection writeData:payload withTimeout:-1 tag:3];
}

-(void)disconnect
{
    NSArray *tmpConnections = [NSArray arrayWithArray:connections];
    
    [tmpConnections enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        GCDAsyncSocket *connection = (GCDAsyncSocket*) obj;
        [connection disconnect];
    }];
    [socket disconnect];
}

- (NSString *)handshakeResponseForData:(NSData *)data {
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *strings = [string componentsSeparatedByString:@"\r\n"];

    if (strings.count && [strings[0] isEqualToString:@"GET / HTTP/1.1"])
        for (NSString *line in strings) {
            NSArray *parts = [line componentsSeparatedByString:@":"];
            if (parts.count == 2 && [parts[0] isEqualToString:@"Sec-WebSocket-Key"]) {
                id key = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                id secWebSocketAccept = [[key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"] sha1base64];
                return [NSString stringWithFormat:
                        @"HTTP/1.1 101 Web Socket Protocol Handshake\r\n"
                        "Upgrade: websocket\r\n"
                        "Connection: Upgrade\r\n"
                        "Sec-WebSocket-Accept: %@\r\n\r\n",
                        secWebSocketAccept];
            }
        }

    @throw @"Invalid handshake from client";
}


#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)connection {
    [connections addObject:connection];
    [connection readDataWithTimeout:-1 tag:1];
}

- (void)socket:(GCDAsyncSocket *)connection didReadData:(NSData *)data withTag:(long)tag
{
    @try {
        const unsigned char *bytes = data.bytes;
        switch (tag) {
            case 1: {
                NSString *handshake = [self handshakeResponseForData:data];
                [connection writeData:[handshake dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:2];
                break;
            }
            case 4: {
                uint64_t const N = bytes[1] & 0x7f;

                if (!bytes[0] & 0x81)
                    @throw @"Cannot handle this websocket frame format!";
                if (!bytes[1] & 0x80)
                    @throw @"Can only handle websocket frames with masks!";
                if (N >= 126)
                    [connection readDataToLength:N == 126 ? 2 : 8 withTimeout:-1 buffer:nil bufferOffset:0 tag:5];
                else
                    [connection readDataToLength:N + 4 withTimeout:-1 buffer:nil bufferOffset:0 tag:6];
                break;
            }
            case 5: {
                if (data.length == 2) {
                    uint16_t *p = (uint16_t *)bytes;
                    [connection readDataToLength:ntohs(*p) + 4 withTimeout:-1 buffer:nil bufferOffset:0 tag:6];
                } else {
                    uint64_t *p = (uint64_t *)bytes;
                    [connection readDataToLength:ntohll(*p) + 4 withTimeout:-1 buffer:nil bufferOffset:0 tag:6];
                }
                break;
            }
            case 6: {
                NSMutableData *unmaskedData = [NSMutableData dataWithCapacity:data.length - 4];
                for (int x = 4; x < data.length; ++x) {
                    char c = bytes[x] ^ bytes[x%4];
                    [unmaskedData appendBytes:&c length:1];
                }

                if (data.length - 4 > 0)
                {
                    NSData *rangedData = [unmaskedData subdataWithRange:NSMakeRange(0, data.length - 4)];
                
                    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                        [_delegate webSocketServer:self didReceiveData:rangedData fromConnection:connection];
                    }];
                }

                [connection readDataToLength:2 withTimeout:-1 buffer:nil bufferOffset:0 tag:4];
                break;
            }
        }
    }
    @catch (id e) {
        NSLog(@"MBWebSocketServer: %@", e);
        [connection disconnect];
    }
}

- (void)socket:(GCDAsyncSocket *)connection didWriteDataWithTag:(long)tag {
    if (tag == 2) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [_delegate webSocketServer:self didAcceptConnection:connection];
        }];
        [connection readDataToLength:2 withTimeout:-1 buffer:nil bufferOffset:0 tag:4];
    }
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)connection withError:(NSError *)error {
    [connections removeObjectIdenticalTo:connection];
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [_delegate webSocketServer:self clientDisconnected:connection];
    }];
}

@end



@implementation NSString (MBWebSocketServer)

- (id)sha1base64 {
    NSMutableData* data = (id) [self dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char input[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (unsigned)data.length, input);

//////
    static const char map[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    
    data = [NSMutableData dataWithLength:28];
    uint8_t* out = (uint8_t*) data.mutableBytes;
    
    for (int i = 0; i < 20;) {
        int v  = 0;
        for (const int N = i + 3; i < N; i++) {
            v <<= 8;
            v |= 0xFF & input[i];
        }
        *out++ = map[v >> 18 & 0x3F];
        *out++ = map[v >> 12 & 0x3F];
        *out++ = map[v >> 6 & 0x3F];
        *out++ = map[v >> 0 & 0x3F];
    }
    out[-2] = map[(input[19] & 0x0F) << 2];
    out[-1] = '=';
    return [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
}

- (id)webSocketFrameData {
    return [[self dataUsingEncoding:NSUTF8StringEncoding] webSocketFrameData];
}

@end



@implementation NSData (MBWebSocketServer)

- (id)webSocketFrameData {
    NSMutableData *data = [NSMutableData dataWithLength:10];
    char *header = data.mutableBytes;
    header[0] = 0x81;

    if (self.length > 65535) {
        header[1] = 127;
        header[2] = (self.length >> 56) & 255;
        header[3] = (self.length >> 48) & 255;
        header[4] = (self.length >> 40) & 255;
        header[5] = (self.length >> 32) & 255;
        header[6] = (self.length >> 24) & 255;
        header[7] = (self.length >> 16) & 255;
        header[8] = (self.length >>  8) & 255;
        header[9] = self.length & 255;
    } else if (self.length > 125) {
        header[1] = 126;
        header[2] = (self.length >> 8) & 255;
        header[3] = self.length & 255;
        data.length = 4;
    } else {
        header[1] = self.length;
        data.length = 2;
    }

    [data appendData:self];

    return data;
}

@end



@implementation GCDAsyncSocket (MBWebSocketServer)

- (void)writeWebSocketFrame:(id)object {
    [self writeData:[object webSocketFrameData] withTimeout:-1 tag:3];
}

@end
