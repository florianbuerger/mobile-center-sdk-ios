/*
 * Copyright (c) Microsoft Corporation. All rights reserved.
 */

#import "MSErrorReport.h"
#import "MSErrorReportPrivate.h"

NSString *const kMSErrorReportKillSignal = @"SIGKILL";

@implementation MSErrorReport

- (instancetype)initWithErrorId:(NSString *)errorId
                    reporterKey:(NSString *)reporterKey
                         signal:(NSString *)signal
                  exceptionName:(NSString *)exceptionName
                exceptionReason:(NSString *)exceptionReason
                   appStartTime:(NSDate *)appStartTime
                   appErrorTime:(NSDate *)appErrorTime
                         device:(MSDevice *)device
           appProcessIdentifier:(NSUInteger)appProcessIdentifier {

  if ((self = [super init])) {
    _incidentIdentifier = errorId;
    _reporterKey = reporterKey;
    _signal = signal;
    _exceptionName = exceptionName;
    _exceptionReason = exceptionReason;
    _appStartTime = appStartTime;
    _appErrorTime = appErrorTime;
    _device = device;
    _appProcessIdentifier = appProcessIdentifier;
  }
  return self;
}

- (BOOL)isAppKill {
  BOOL result = NO;

  if (_signal && [[_signal uppercaseString] isEqualToString:kMSErrorReportKillSignal])
    result = YES;

  return result;
}

@end
