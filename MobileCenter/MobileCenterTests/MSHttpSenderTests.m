/*
 * Copyright (c) Microsoft Corporation. All rights reserved.
 */

#import "MSDevice.h"
#import "MSDevicePrivate.h"
#import "MSHttpSender.h"
#import "MSHttpSenderPrivate.h"
#import "MSHttpTestUtil.h"
#import "MSMobileCenterErrors.h"
#import "MSMockLog.h"
#import "MSRetriableCall.h"
#import "MSSenderDelegate.h"
#import "MobileCenter+Internal.h"

#import "OCMock.h"
#import <OCHamcrestIOS/OCHamcrestIOS.h>
#import <XCTest/XCTest.h>

static NSTimeInterval const kMSTestTimeout = 5.0;
static NSString *const kMSBaseUrl = @"https://test.com";
static NSString *const kMSAppSecret = @"mockAppSecret";

@interface MSHttpSenderTests : XCTestCase

@property(nonatomic, strong) MSHttpSender *sut;
@property(nonatomic, strong) id reachabilityMock;
@property(nonatomic) NetworkStatus currentNetworkStatus;

@end

@implementation MSHttpSenderTests

- (void)setUp {
  [super setUp];

  NSDictionary *headers = @{
    @"Content-Type" : @"application/json",
    @"App-Secret" : @"myUnitTestAppSecret",
    @"Install-ID" : MS_UUID_STRING
  };

  NSDictionary *queryStrings = @{ @"api_version" : @"1.0.0-preview20160914" };

  // Mock reachability.
  self.reachabilityMock = OCMClassMock([MS_Reachability class]);
  self.currentNetworkStatus = ReachableViaWiFi;
  OCMStub([self.reachabilityMock currentReachabilityStatus]).andDo(^(NSInvocation *invocation) {
    NetworkStatus test = self.currentNetworkStatus;
    [invocation setReturnValue:&test];
  });

  // sut: System under test
  self.sut = [[MSHttpSender alloc] initWithBaseUrl:kMSBaseUrl
                                           headers:headers
                                      queryStrings:queryStrings
                                      reachability:self.reachabilityMock];

  // Set short retry intervals
  self.sut.callsRetryIntervals = @[ @(0.5), @(1), @(1.5) ];
}

- (void)tearDown {
  [super tearDown];

  [OHHTTPStubs removeAllStubs];
}

- (void)testSendBatchLogs {

  // Stub http response
  [MSHttpTestUtil stubHttp200Response];
  NSString *containerId = @"1";
  MSLogContainer *container = [self createLogContainerWithId:containerId];

  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"HTTP Response 200"];
  [self.sut sendAsync:container
      completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {

        XCTAssertNil(error);
        XCTAssertEqual(containerId, batchId);
        XCTAssertEqual(statusCode, MSHTTPCodesNo200OK);

        [expectation fulfill];
      }];

  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *_Nullable error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testUnrecoverableError {

  // Stub http response
  [MSHttpTestUtil stubHttp404Response];
  NSString *containerId = @"1";
  MSLogContainer *container = [self createLogContainerWithId:containerId];

  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"HTTP Response 200"];
  [self.sut sendAsync:container
      completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {

        XCTAssertEqual(containerId, batchId);
        XCTAssertEqual(statusCode, MSHTTPCodesNo404NotFound);
        XCTAssertEqual(error.domain, kMSMCErrorDomain);
        XCTAssertEqual(error.code, kMSMCConnectionHttpErrorCode);
        XCTAssertEqual(error.localizedDescription, kMSMCConnectionHttpErrorDesc);
        XCTAssertTrue([error.userInfo[kMSMCConnectionHttpCodeErrorKey] isEqual:@(MSHTTPCodesNo404NotFound)]);
        [expectation fulfill];
      }];

  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *_Nullable error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testNetworkDown {

  /**
   * If
   */
  [MSHttpTestUtil stubNetworkDownResponse];
  XCTestExpectation *requestCompletedExcpectation = [self expectationWithDescription:@"Request completed."];
  MSLogContainer *container = [self createLogContainerWithId:@"1"];

  // Set a delegate for suspending event.
  id delegateMock = OCMProtocolMock(@protocol(MSSenderDelegate));
  OCMStub([delegateMock senderDidSuspend:self.sut]).andDo(^(NSInvocation *invocation) {
    [requestCompletedExcpectation fulfill];
  });
  [self.sut addDelegate:delegateMock];

  /**
   * When
   */
  [self.sut sendAsync:container
      completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {

        // This should not be happening.
        XCTFail(@"Completion handler should'nt be called on recoverable errors.");
      }];

  /**
   * Then
   */
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {

                                 // The call must still be in the pending calls, intended to be retried later.
                                 assertThatUnsignedLong(self.sut.pendingCalls.count, equalToInt(1));

                                 // Sender must be suspended when network is down.
                                 assertThatBool(self.sut.suspended, isTrue());
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testNetworkUpAgain {

  /**
   * If
   */
  XCTestExpectation *requestCompletedExcpectation = [self expectationWithDescription:@"Request completed."];
  __block NSInteger forwardedStatus;
  __block NSError *forwardedError;
  [MSHttpTestUtil stubHttp200Response];
  MSLogContainer *container = [self createLogContainerWithId:@"1"];

  // Set a delegate for suspending/resuming event.
  id delegateMock = OCMProtocolMock(@protocol(MSSenderDelegate));
  [self.sut addDelegate:delegateMock];
  OCMStub([delegateMock senderDidSuspend:self.sut]).andDo(^(NSInvocation *invocation) {

    // Send one batch now that the sender is suspended.
    [self.sut sendAsync:container
        completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {
          forwardedStatus = statusCode;
          forwardedError = error;
          [requestCompletedExcpectation fulfill];
        }];

    /**
     * When
     */

    // Simulate network up again.
    [self simulateReachabilityChangedNotification:ReachableViaWiFi];
  });

  // Simulate network is down.
  [self simulateReachabilityChangedNotification:NotReachable];

  /**
   * Then
   */
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {

                                 // The sender got resumed.
                                 OCMVerify([delegateMock senderDidResume:self.sut]);
                                 assertThatBool(self.sut.suspended, isFalse());

                                 // The call as been removed.
                                 assertThatUnsignedLong(self.sut.pendingCalls.count, equalToInt(0));

                                 // Status codes and error must be the same.
                                 assertThatLong(MSHTTPCodesNo200OK, equalToLong(forwardedStatus));
                                 assertThat(forwardedError, nilValue());
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testTasksSuspendedOnSenderSuspended {

  /**
   * If
   */
  XCTestExpectation *tasksListedExpectation = [self expectationWithDescription:@"URL Session tasks listed."];
  __block NSArray<NSURLSessionDataTask *> *tasks;
  [MSHttpTestUtil stubLongTimeOutResponse];
  MSLogContainer *container1 = [self createLogContainerWithId:@"1"];
  MSLogContainer *container2 = [self createLogContainerWithId:@"2"];

  // Send logs
  [self.sut sendAsync:container1
      completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {
        XCTFail(@"Completion handler shouldn't be called as test will finish before the response timeout.");
      }];
  [self.sut sendAsync:container2
      completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {
        XCTFail(@"Completion handler shouldn't be called as test will finish before the response timeout.");
      }];

  /**
   * When
   */
  [self.sut suspend];
  [self.sut.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *_Nonnull dataTasks,
                                                    NSArray<NSURLSessionUploadTask *> *_Nonnull uploadTasks,
                                                    NSArray<NSURLSessionDownloadTask *> *_Nonnull downloadTasks) {
    tasks = dataTasks;
    [tasksListedExpectation fulfill];
  }];

  /**
   * Then
   */
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {

                                 // Must be only two tasks
                                 assertThatInteger(tasks.count, equalToInteger(2));

                                 // Tasks must be suspended.
                                 [tasks enumerateObjectsUsingBlock:^(__kindof NSURLSessionTask *_Nonnull task,
                                                                     NSUInteger idx, BOOL *_Nonnull stop) {
                                   assertThatInteger(task.state, equalToInteger(NSURLSessionTaskStateSuspended));
                                 }];

                                 // Sender must be suspended.
                                 assertThatBool(self.sut.suspended, isTrue());

                                 // Calls must still be in the pending calls, intended to be resumed later.
                                 assertThatUnsignedLong(self.sut.pendingCalls.count, equalToInt(2));

                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testTasksRunningOnSenderResumed {

  /**
   * If
   */
  XCTestExpectation *tasksListedExpectation = [self expectationWithDescription:@"Container 1 sent."];
  __block NSArray<NSURLSessionDataTask *> *tasks;
  [MSHttpTestUtil stubLongTimeOutResponse];
  MSLogContainer *container1 = [self createLogContainerWithId:@"1"];
  MSLogContainer *container2 = [self createLogContainerWithId:@"2"];

  // Send logs
  [self.sut sendAsync:container1
      completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {
        XCTFail(@"Completion handler shouldn't be called as test will finish before the response timeout.");
      }];
  [self.sut sendAsync:container2
      completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {
        XCTFail(@"Completion handler shouldn't be called as test will finish before the response timeout.");
      }];
  [self.sut suspend];

  /**
   * When
   */
  [self.sut resume];
  [self.sut.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *_Nonnull dataTasks,
                                                    NSArray<NSURLSessionUploadTask *> *_Nonnull uploadTasks,
                                                    NSArray<NSURLSessionDownloadTask *> *_Nonnull downloadTasks) {
    // Capture tasks state.
    tasks = dataTasks;
    [tasksListedExpectation fulfill];
  }];

  /**
   * Then
   */
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {

                                 // Must be only two tasks
                                 assertThatInteger(tasks.count, equalToInteger(2));

                                 // Tasks must have been resumed.
                                 [tasks enumerateObjectsUsingBlock:^(__kindof NSURLSessionDataTask *_Nonnull task,
                                                                     NSUInteger idx, BOOL *_Nonnull stop) {
                                   assertThatInteger(task.state, equalToInteger(NSURLSessionTaskStateRunning));
                                 }];

                                 // Sender must be suspended.
                                 assertThatBool(self.sut.suspended, isFalse());

                                 // Calls must still be in the pending calls, not yet timed out.
                                 assertThatUnsignedLong(self.sut.pendingCalls.count, equalToInt(2));

                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testRetryStoppedWhileSuspended {

  /**
   * If
   */
  XCTestExpectation *responseReceivedExcpectation = [self expectationWithDescription:@"Request completed."];
  NSString *containerId = @"1";
  MSLogContainer *container = [self createLogContainerWithId:containerId];

  // Mock the call to intercept the retry.
  MSRetriableCall *mockedCall = OCMPartialMock([[MSRetriableCall alloc] initWithRetryIntervals:@[ @(UINT_MAX) ]]);
  mockedCall.delegate = self.sut;
  mockedCall.logContainer = container;
  mockedCall.completionHandler = nil;
  OCMStub([mockedCall sender:self.sut callCompletedWithStatus:MSHTTPCodesNo500InternalServerError error:[OCMArg any]])
      .andForwardToRealObject()
      .andDo(^(NSInvocation *invocation) {
        [responseReceivedExcpectation fulfill];
      });
  self.sut.pendingCalls[containerId] = mockedCall;

  // Respond with a retryable error.
  [MSHttpTestUtil stubHttp500Response];

  // Send the call.
  [self.sut sendCallAsync:mockedCall];
  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *error) {

                                 /**
                                  * When
                                  */

                                 // Suspend now that the call is retrying.
                                 [self.sut suspend];

                                 /**
                                  * Then
                                  */

                                 // Retry must be stopped.
                                 assertThat(((MSRetriableCall *)self.sut.pendingCalls[@"1"]).timerSource, nilValue());

                                 // No call submitted to the session.
                                 assertThatBool(self.sut.pendingCalls[@"1"].submitted, isFalse());
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testInvalidContainer {

  MSMockLog *log1 = [[MSMockLog alloc] init];
  log1.sid = MS_UUID_STRING;
  log1.toffset = [NSNumber numberWithLongLong:[MSUtil nowInMilliseconds]];

  // Log does not have device info, therefore, it's an invalid log
  MSLogContainer *container = [[MSLogContainer alloc] initWithBatchId:@"1" andLogs:(NSArray<MSLog> *)@[ log1 ]];

  [self.sut sendAsync:container
      completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {

        XCTAssertEqual(error.domain, kMSMCErrorDomain);
        XCTAssertEqual(error.code, kMSMCLogInvalidContainerErrorCode);
      }];

  XCTAssertEqual([self.sut.pendingCalls count], 0);
}

- (void)testNilContainer {

  MSLogContainer *container = nil;

  __weak XCTestExpectation *expectation = [self expectationWithDescription:@"HTTP Network Down"];
  [self.sut sendAsync:container
      completionHandler:^(NSString *batchId, NSError *error, NSUInteger statusCode) {

        XCTAssertNotNil(error);
        [expectation fulfill];

      }];

  [self waitForExpectationsWithTimeout:kMSTestTimeout
                               handler:^(NSError *_Nullable error) {
                                 if (error) {
                                   XCTFail(@"Expectation Failed with error: %@", error);
                                 }
                               }];
}

- (void)testAddDelegate {

  // If.
  id delegateMock = OCMProtocolMock(@protocol(MSSenderDelegate));

  // When.
  [self.sut addDelegate:delegateMock];

  // Then.
  assertThatBool([self.sut.delegates containsObject:delegateMock], isTrue());
}

- (void)testAddMultipleDelegates {

  // If.
  id delegateMock1 = OCMProtocolMock(@protocol(MSSenderDelegate));
  id delegateMock2 = OCMProtocolMock(@protocol(MSSenderDelegate));

  // When.
  [self.sut addDelegate:delegateMock1];
  [self.sut addDelegate:delegateMock2];

  // Then.
  assertThatBool([self.sut.delegates containsObject:delegateMock1], isTrue());
  assertThatBool([self.sut.delegates containsObject:delegateMock2], isTrue());
}

- (void)testAddTwiceSameDelegate {

  // If.
  id delegateMock = OCMProtocolMock(@protocol(MSSenderDelegate));

  // When.
  [self.sut addDelegate:delegateMock];
  [self.sut addDelegate:delegateMock];

  // Then.
  assertThatBool([self.sut.delegates containsObject:delegateMock], isTrue());
  assertThatUnsignedLong(self.sut.delegates.count, equalToInt(1));
}

- (void)testRemoveDelegate {

  // If.
  id delegateMock = OCMProtocolMock(@protocol(MSSenderDelegate));
  [self.sut addDelegate:delegateMock];

  // When.
  [self.sut removeDelegate:delegateMock];

  // Then.
  assertThatBool([self.sut.delegates containsObject:delegateMock], isFalse());
}

- (void)testRemoveTwiceSameDelegate {

  // If.
  id delegateMock1 = OCMProtocolMock(@protocol(MSSenderDelegate));
  id delegateMock2 = OCMProtocolMock(@protocol(MSSenderDelegate));
  [self.sut addDelegate:delegateMock1];
  [self.sut addDelegate:delegateMock2];

  // When.
  [self.sut removeDelegate:delegateMock1];
  [self.sut removeDelegate:delegateMock1];

  // Then.
  assertThatBool([self.sut.delegates containsObject:delegateMock1], isFalse());
  assertThatBool([self.sut.delegates containsObject:delegateMock2], isTrue());
  assertThatUnsignedLong(self.sut.delegates.count, equalToInt(1));
}

- (void)testNullifiedDelegate {

  // If.
  @autoreleasepool {
    __weak id delegateMock = OCMProtocolMock(@protocol(MSSenderDelegate));
    [self.sut addDelegate:delegateMock];

    // When.
    delegateMock = nil;
  }

  // Then.
  // There is a bug somehow in NSHashTable where the count on the table itself is not decremented while an object is
  // deallocated and auto removed from the table. The NSHashtable allObjects: is used instead to remediate.
  assertThatUnsignedLong(self.sut.delegates.allObjects.count, equalToInt(0));
}

- (void)testCallDelegatesOnSuspended {

  // If.
  id delegateMock1 = OCMProtocolMock(@protocol(MSSenderDelegate));
  id delegateMock2 = OCMProtocolMock(@protocol(MSSenderDelegate));
  [self.sut resume];
  [self.sut addDelegate:delegateMock1];
  [self.sut addDelegate:delegateMock2];

  // When.
  [self.sut suspend];

  // Then.
  OCMVerify([delegateMock1 senderDidSuspend:self.sut]);
  OCMVerify([delegateMock2 senderDidSuspend:self.sut]);
}

- (void)testCallDelegatesOnResumed {

  // If.
  id delegateMock1 = OCMProtocolMock(@protocol(MSSenderDelegate));
  id delegateMock2 = OCMProtocolMock(@protocol(MSSenderDelegate));
  [self.sut suspend];
  [self.sut addDelegate:delegateMock1];
  [self.sut addDelegate:delegateMock2];

  // When.
  [self.sut suspend];
  [self.sut resume];

  // Then.
  OCMVerify([delegateMock1 senderDidResume:self.sut]);
  OCMVerify([delegateMock2 senderDidResume:self.sut]);
}

- (void)testLargeSecret {

  // If.
  NSString *secret = @"shhhh-its-a-secret";
  NSString *hiddenSecret;

  // When.
  hiddenSecret = [self.sut hideSecret:secret];

  // Then.
  NSString *fullyHiddenSecret =
      [@"" stringByPaddingToLength:hiddenSecret.length withString:kMSHidingStringForAppSecret startingAtIndex:0];
  NSString *appSecretHiddenPart = [hiddenSecret commonPrefixWithString:fullyHiddenSecret options:0];
  NSString *appSecretVisiblePart = [hiddenSecret substringFromIndex:appSecretHiddenPart.length];
  assertThatInteger(secret.length - appSecretHiddenPart.length, equalToShort(kMSMaxCharactersDisplayedForAppSecret));
  assertThat(appSecretVisiblePart, is([secret substringFromIndex:appSecretHiddenPart.length]));
}

- (void)testShortSecret {

  // If.
  NSString *secret = @"";
  for (short i = 1; i <= kMSMaxCharactersDisplayedForAppSecret - 1; i++)
    secret = [NSString stringWithFormat:@"%@%hd", secret, i];
  NSString *hiddenSecret;

  // When.
  hiddenSecret = [self.sut hideSecret:secret];

  // Then.
  NSString *fullyHiddenSecret =
      [@"" stringByPaddingToLength:hiddenSecret.length withString:kMSHidingStringForAppSecret startingAtIndex:0];
  assertThatInteger(hiddenSecret.length, equalToInteger(secret.length));
  assertThat(hiddenSecret, is(fullyHiddenSecret));
}

#pragma mark - Test Helpers

- (void)simulateReachabilityChangedNotification:(NetworkStatus)status {
  self.currentNetworkStatus = status;
  [[NSNotificationCenter defaultCenter] postNotificationName:kMSReachabilityChangedNotification
                                                      object:self.reachabilityMock];
}

- (MSLogContainer *)createLogContainerWithId:(NSString *)batchId {

  MSDevice *device = [[MSDevice alloc] init];
  device.sdkVersion = @"1.0.0";

  MSMockLog *log1 = [[MSMockLog alloc] init];
  log1.sid = MS_UUID_STRING;
  log1.toffset = [NSNumber numberWithLongLong:[MSUtil nowInMilliseconds]];
  log1.device = device;

  MSMockLog *log2 = [[MSMockLog alloc] init];
  log2.sid = MS_UUID_STRING;
  log2.toffset = [NSNumber numberWithLongLong:[MSUtil nowInMilliseconds]];
  log2.device = device;

  MSLogContainer *logContainer =
      [[MSLogContainer alloc] initWithBatchId:batchId andLogs:(NSArray<MSLog> *)@[ log1, log2 ]];
  return logContainer;
}

@end
