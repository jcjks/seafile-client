#include <libkern/OSAtomic.h>
#include <mach/mach.h>

#import <Cocoa/Cocoa.h>
#include "finder-sync/finder-sync-host.h"
#include "finder-sync/finder-sync-listener.h"

#if !__has_feature(objc_arc)
#error this file must be built with ARC support
#endif

@interface FinderSyncListener : NSObject <NSMachPortDelegate>
@end

enum CommandType {
    GetWatchSet = 0,
    DoShareLink,
};

struct mach_msg_command_send_t {
  mach_msg_header_t header;
  char body[kPathMaxSize];
  int command;
};

struct mach_msg_command_rcv_t {
    mach_msg_header_t header;
    char body[kPathMaxSize];
    int command;
    mach_msg_trailer_t trailer;
};

struct mach_msg_watchdir_send_t {
    mach_msg_header_t header;
    watch_dir_t dirs[kWatchDirMax];
};

namespace {

NSString *const kFinderSyncMachPort =
    @"com.seafile.seafile-client.findersync.machport";

// listener related
NSThread *finder_sync_listener_thread_ = nil;
// atomic value
int32_t finder_sync_started_ = 0;
FinderSyncListener *finder_sync_listener_ = nil;
std::unique_ptr<FinderSyncHost> finder_sync_host_;

} // anonymous namespace

@interface FinderSyncListener ()
@property(readwrite, nonatomic, strong) NSPort *listenerPort;
@end

@implementation FinderSyncListener
- (instancetype)init {
    self = [super init];
    self.listenerPort = nil;
    return self;
}
- (void)start {
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    mach_port_t port = MACH_PORT_NULL;

    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &port);
    if (kr != KERN_SUCCESS) {
        NSLog(@"failed to allocate mach port %@", kFinderSyncMachPort);
        NSLog(@"mach error %s", mach_error_string(kr));
        kr = mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
        if (kr != KERN_SUCCESS) {
            NSLog(@"failed to deallocate mach port %@", kFinderSyncMachPort);
            NSLog(@"mach error %s", mach_error_string(kr));
        }
        return;
    }

    kr = mach_port_insert_right(mach_task_self(), port, port,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
      NSLog(@"failed to insert send right to mach port %@", kFinderSyncMachPort);
      NSLog(@"mach error %s", mach_error_string(kr));
      kr = mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
      if (kr != KERN_SUCCESS) {
          NSLog(@"failed to deallocate mach port %@", kFinderSyncMachPort);
          NSLog(@"mach error %s", mach_error_string(kr));
      }
      NSLog(@"failed to allocate send right tp local mach port");
      return;
    }
    self.listenerPort = [NSMachPort portWithMachPort:port
                                             options:NSMachPortDeallocateReceiveRight];
    if (![[NSMachBootstrapServer sharedInstance] registerPort:self.listenerPort
        name:kFinderSyncMachPort]) {
        [self.listenerPort invalidate];
        NSLog(@"failed to register mach port %@", kFinderSyncMachPort);
        NSLog(@"mach error %s", mach_error_string(kr));
        return;
    }
    NSLog(@"registered mach port");
    [self.listenerPort setDelegate:self];
    [runLoop addPort:self.listenerPort forMode:NSDefaultRunLoopMode];
    while (finder_sync_started_)
        [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    [self.listenerPort invalidate];
    NSLog(@"unregistered mach port");
    kr = mach_port_deallocate(mach_task_self(), port);
    if (kr != KERN_SUCCESS) {
        NSLog(@"failed to deallocate mach port %u", port);
        return;
    }
}
- (void)stop {
    CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void)handleMachMessage:(void *)machMessage {
    mach_msg_command_rcv_t *msg = static_cast<mach_msg_command_rcv_t *>(machMessage);
    if (msg->header.msgh_size != sizeof(mach_msg_command_send_t)) {
        NSLog(@"received msg with bad size %u from remote_port:%u",
              msg->header.msgh_size, msg->header.msgh_remote_port);
        mach_msg_destroy(&msg->header);
        return;
    }

    switch (msg->command) {
    case DoShareLink:
        QMetaObject::invokeMethod(finder_sync_host_.get(), "doShareLink",
                                  Qt::QueuedConnection,
                                  Q_ARG(QString, msg->body));
        mach_msg_destroy(&msg->header);
        return;
    case GetWatchSet:
        break;
    default:
        NSLog(@"received unknown command %u from remote_port:%u", msg->command,
              msg->header.msgh_remote_port);
        mach_msg_destroy(&msg->header);
        return;
    }

    // generate reply
    mach_port_t port = msg->header.msgh_remote_port;
    if (!port) {
        return;
    }
    mach_msg_watchdir_send_t reply_msg;
    size_t count = finder_sync_host_->getWatchSet(reply_msg.dirs, kWatchDirMax);
    bzero(&reply_msg, sizeof(mach_msg_header_t));
    reply_msg.header.msgh_id = msg->header.msgh_id + 100;
    reply_msg.header.msgh_size = sizeof(mach_msg_header_t) + count * sizeof(watch_dir_t);
    reply_msg.header.msgh_local_port = MACH_PORT_NULL;
    reply_msg.header.msgh_remote_port = port;
    reply_msg.header.msgh_bits = MACH_MSGH_BITS_REMOTE(msg->header.msgh_bits);

    // send the reply
    kern_return_t kr = mach_msg_send(&reply_msg.header);
    if (kr != MACH_MSG_SUCCESS) {
        NSLog(@"mach error %s", mach_error_string(kr));
        NSLog(@"failed to send reply to remote mach port %u", port);
        return;
    }

    // destroy
    mach_msg_destroy(&msg->header);
    mach_msg_destroy(&reply_msg.header);
}

@end

void finderSyncListenerStart() {
    if (!finder_sync_started_) {
        // this value is used in different threads
        // keep it in atomic and guarenteed by barrier for safety
        OSAtomicIncrement32Barrier(&finder_sync_started_);

        finder_sync_host_.reset(new FinderSyncHost);
        finder_sync_listener_ = [[FinderSyncListener alloc] init];
        finder_sync_listener_thread_ =
            [[NSThread alloc] initWithTarget:finder_sync_listener_
                                    selector:@selector(start)
                                      object:nil];
        [finder_sync_listener_thread_ start];
    }
}

void finderSyncListenerStop() {
    if (finder_sync_started_) {
        // this value is used in different threads
        // keep it in atomic and guarenteed by barrier for safety
        OSAtomicDecrement32Barrier(&finder_sync_started_);

        // tell finder_sync_listener_ to exit
        [finder_sync_listener_ performSelector:@selector(stop)
                                     onThread:finder_sync_listener_thread_
                                   withObject:nil
                                waitUntilDone:NO];
        finder_sync_host_.reset();
    }
}
