//
//  AudioStreamer.m
//  StreamingAudioPlayer
//
//  Created by Matt Gallagher on 27/09/08.
//  Copyright 2008 Matt Gallagher. All rights reserved.
//
//  This software is provided 'as-is', without any express or implied
//  warranty. In no event will the authors be held liable for any damages
//  arising from the use of this software. Permission is granted to anyone to
//  use this software for any purpose, including commercial applications, and to
//  alter it and redistribute it freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//  3. This notice may not be removed or altered from any source
//     distribution.
//

#import "AudioStreamer.h"
#if TARGET_OS_IPHONE			
#import <AVFoundation/AVFoundation.h>
#import <CFNetwork/CFNetwork.h>
#endif

#define BitRateEstimationMaxPackets 5000
#define BitRateEstimationMinPackets 50

NSString * const ASStatusChangedNotification = @"ASStatusChangedNotification";
NSString * const ASAudioSessionInterruptionOccuredNotification = @"ASAudioSessionInterruptionOccuredNotification";

static const char * internalQueueToken = "com.voodoo77.AudioStreamerInternal";

@interface AudioStreamer () <NSStreamDelegate>
{
	dispatch_semaphore_t bufferSemaphore;
	dispatch_queue_t internalQueue;
}

@property (nonatomic, assign, readwrite) AudioStreamerErrorCode errorCode;
@property (nonatomic, assign, readwrite) AudioStreamerState lastState;
@property (nonatomic, assign, readwrite) AudioStreamerState state;
@property (nonatomic, assign, readwrite) AudioStreamerStopReason stopReason;

- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
	fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
	ioFlags:(UInt32 *)ioFlags;
- (void)handleAudioPackets:(const void *)inInputData
	numberBytes:(UInt32)inNumberBytes
	numberPackets:(UInt32)inNumberPackets
	packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions;
- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ
	buffer:(AudioQueueBufferRef)inBuffer;
- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ
	propertyID:(AudioQueuePropertyID)inID;

#if TARGET_OS_IPHONE
- (void)handleInterruptionChangeToState:(NSNotification *)notification;
#endif

- (void)internalSeekToTime:(double)newSeekTime;
- (void)enqueueBuffer;

@end

#pragma mark Audio Callback Function Implementations

//
// ASPropertyListenerProc
//
// Receives notification when the AudioFileStream has audio packets to be
// played. In response, this function creates the AudioQueue, getting it
// ready to begin playback (playback won't begin until audio packets are
// sent to the queue in ASEnqueueBuffer).
//
// This function is adapted from Apple's example in AudioFileStreamExample with
// kAudioQueueProperty_IsRunning listening added.
//
static void ASPropertyListenerProc(void *						inClientData,
								AudioFileStreamID				inAudioFileStream,
								AudioFileStreamPropertyID		inPropertyID,
								UInt32 *						ioFlags)
{	
	// this is called by audio file stream when it finds property values
	AudioStreamer* streamer = (__bridge AudioStreamer *)inClientData;
	[streamer
		handlePropertyChangeForFileStream:inAudioFileStream
		fileStreamPropertyID:inPropertyID
		ioFlags:ioFlags];
}

//
// ASPacketsProc
//
// When the AudioStream has packets to be played, this function gets an
// idle audio buffer and copies the audio packets into it. The calls to
// ASEnqueueBuffer won't return until there are buffers available (or the
// playback has been stopped).
//
// This function is adapted from Apple's example in AudioFileStreamExample with
// CBR functionality added.
//
static void ASPacketsProc(		void *							inClientData,
								UInt32							inNumberBytes,
								UInt32							inNumberPackets,
								const void *					inInputData,
								AudioStreamPacketDescription	*inPacketDescriptions)
{
	// this is called by audio file stream when it finds packets of audio
	AudioStreamer* streamer = (__bridge AudioStreamer *)inClientData;
	[streamer
		handleAudioPackets:inInputData
		numberBytes:inNumberBytes
		numberPackets:inNumberPackets
		packetDescriptions:inPacketDescriptions];
}

//
// ASAudioQueueOutputCallback
//
// Called from the AudioQueue when playback of specific buffers completes. This
// function signals from the AudioQueue thread to the AudioStream thread that
// the buffer is idle and available for copying data.
//
// This function is unchanged from Apple's example in AudioFileStreamExample.
//
static void ASAudioQueueOutputCallback(void*				inClientData, 
									AudioQueueRef			inAQ, 
									AudioQueueBufferRef		inBuffer)
{
	// this is called by the audio queue when it has finished decoding our data. 
	// The buffer is now free to be reused.
	AudioStreamer* streamer = (__bridge AudioStreamer*)inClientData;
	[streamer handleBufferCompleteForQueue:inAQ buffer:inBuffer];
}

//
// ASAudioQueueIsRunningCallback
//
// Called from the AudioQueue when playback is started or stopped. This
// information is used to toggle the observable "isPlaying" property and
// set the "finished" flag.
//
static void ASAudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID)
{
	AudioStreamer* streamer = (__bridge AudioStreamer *)inUserData;
	[streamer handlePropertyChangeForQueue:inAQ propertyID:inID];
}

static void *queueContext = @"internalQueue";

@implementation AudioStreamer

@synthesize bitRate;
@synthesize httpHeaders;
@synthesize fileExtension;

//
// init
//
// Init method for the object.
//
- (instancetype)init
{
	self = [super init];
	
	if (self)
	{
		[self setup];
	}
	
	return self;
}

//
// initWithURL
//
// Convenience init method for the object.
//
- (instancetype)initWithURL:(NSURL *)aURL
{
	self = [super init];
	if (self != nil)
	{
		_url = aURL;
		
		[self setup];
	}
	return self;
}

- (void)setup
{
	internalQueue = dispatch_queue_create(internalQueueToken, DISPATCH_QUEUE_SERIAL);
	dispatch_queue_set_specific(internalQueue, queueContext, (void *)queueContext, nil);
	
	_mediaType = AudioStreamMediaTypeMusic;
	_playbackRate = 1.0;
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInterruptionChangeToState:) name:AVAudioSessionInterruptionNotification object:nil];
}

//
// dealloc
//
// Releases instance memory.
//
- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self stop];
	_url = nil;
	fileExtension = nil;
}

//
// isFinishing
//
// returns YES if the audio has reached a stopping condition.
//
- (BOOL)isFinishing
{
	return ((self.errorCode != AudioStreamerErrorCodeNone && self.state != AudioStreamerStateInitialized) ||
			((self.state == AudioStreamerStateStopping || self.state == AudioStreamerStateStopped) &&
			 self.stopReason != AudioStreamerStopReasonTemporary));
}

//
// runLoopShouldExit
//
// returns YES if the run loop should exit.
//
- (BOOL)runLoopShouldExit
{
	return (self.errorCode != AudioStreamerErrorCodeNone ||
			(self.state == AudioStreamerStateStopped &&
			 self.stopReason != AudioStreamerStopReasonTemporary));
}

//
// stringForErrorCode:
//
// Converts an error code to a string that can be localized or presented
// to the user.
//
// Parameters:
//    anErrorCode - the error code to convert
//
// returns the string representation of the error code
//
+ (NSString *)stringForErrorCode:(AudioStreamerErrorCode)anErrorCode
{
	switch (anErrorCode)
	{
		case AudioStreamerErrorCodeNone:
			return NSLocalizedString(@"No error.", @"");
		case AudioStreamerErrorCodeFileStreamSetPropertyFailed:
			return NSLocalizedString(@"File stream set property failed.", @"");
		case AudioStreamerErrorCodeFileStreamGetPropertyFailed:
			return NSLocalizedString(@"File stream get property failed.", @"");
		case AudioStreamerErrorCodeFileStreamSeekFailed:
			return NSLocalizedString(@"File stream seek failed.", @"");
		case AudioStreamerErrorCodeFileStreamParseBytesFailed:
			return NSLocalizedString(@"Parse bytes failed.", @"");
		case AudioStreamerErrorCodeAudioQueueCreationFailed:
			return NSLocalizedString(@"Audio queue creation failed.", @"");
		case AudioStreamerErrorCodeAudioQueueBufferAllocationFailed:
			return NSLocalizedString(@"Audio buffer allocation failed.", @"");
		case AudioStreamerErrorCodeAudioQueueEnqueueFailed:
			return NSLocalizedString(@"Queueing of audio buffer failed.", @"");
		case AudioStreamerErrorCodeAudioQueueAddListenerFailed:
			return NSLocalizedString(@"Audio queue add listener failed.", @"");
		case AudioStreamerErrorCodeAudioQueueRemoveListenerFailed:
			return NSLocalizedString(@"Audio queue remove listener failed.", @"");
		case AudioStreamerErrorCodeAudioQueueStartFailed:
			return NSLocalizedString(@"Audio queue start failed.", @"");
		case AudioStreamerErrorCodeAudioQueueBufferMismatch:
			return NSLocalizedString(@"Audio queue buffers don't match.", @"");
		case AudioStreamerErrorCodeFileStreamOpenFailed:
			return NSLocalizedString(@"Open audio file stream failed.", @"");
		case AudioStreamerErrorCodeFileStreamCloseFailed:
			return NSLocalizedString(@"Close audio file stream failed.", @"");
		case AudioStreamerErrorCodeAudioQueueDisposeFailed:
			return NSLocalizedString(@"Audio queue dispose failed.", @"");
		case AudioStreamerErrorCodeAudioQueuePauseFailed:
			return NSLocalizedString(@"Audio queue pause failed.", @"");
		case AudioStreamerErrorCodeAudioQueueFlushFailed:
			return NSLocalizedString(@"Audio queue flush failed.", @"");
		case AudioStreamerErrorCodeAudioDataNotFound:
			return NSLocalizedString(@"No audio data found.", @"");
		case AudioStreamerErrorCodeGetAudioTimeFailed:
			return NSLocalizedString(@"Audio queue get current time failed.", @"");
		case AudioStreamerErrorCodeNetworkConnectionFailed:
			return NSLocalizedString(@"Network connection failed.", @"");
		case AudioStreamerErrorCodeAudioQueueStopFailed:
			return NSLocalizedString(@"Audio queue stop failed.", @"");
		case AudioStreamerErrorCodeAudioStreamerFailed:
			return NSLocalizedString(@"Audio playback failed.", @"");
		case AudioStreamerErrorCodeAudioBufferTooSmall:
			return NSLocalizedString(@"Audio packets are larger than kAQDefaultBufSize.", @"");
	}
	
	return nil;
}

//
// presentAlertWithTitle:message:
//
// Common code for presenting error dialogs
//
// Parameters:
//    title - title for the dialog
//    message - main test for the dialog
//
- (void)presentAlertWithTitle:(NSString*)title message:(NSString*)message
{
#if TARGET_OS_IPHONE
	dispatch_async(dispatch_get_main_queue(), ^{
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
														message:message
													   delegate:nil
											  cancelButtonTitle:NSLocalizedString(@"OK", @"")
											  otherButtonTitles:nil];
		
		[alert show];
	});
#else
	NSAlert *alert =
		[NSAlert
			alertWithMessageText:title
			defaultButton:NSLocalizedString(@"OK", @"")
			alternateButton:nil
			otherButton:nil
			informativeTextWithFormat:message];
	[alert
		performSelector:@selector(runModal)
		onThread:[NSThread mainThread]
		withObject:nil
		waitUntilDone:NO];
#endif
}

//
// failWithErrorCode:
//
// Sets the playback state to failed and logs the error.
//
// Parameters:
//    anErrorCode - the error condition
//
- (void)failWithErrorCode:(AudioStreamerErrorCode)anErrorCode
{
	if (self.errorCode != AudioStreamerErrorCodeNone)
	{
		// Only set the error once.
		return;
	}
	
	self.errorCode = anErrorCode;
	
	if (err)
	{
		char *errChars = (char *)&err;
		NSLog(@"%@ err: %c%c%c%c %d\n",
			  [AudioStreamer stringForErrorCode:anErrorCode],
			  errChars[3], errChars[2], errChars[1], errChars[0],
			  (int)err);
	}
	else
	{
		NSLog(@"%@", [AudioStreamer stringForErrorCode:anErrorCode]);
	}
	
	if (self.state == AudioStreamerStatePlaying ||
		self.state == AudioStreamerStatePaused ||
		self.state == AudioStreamerStateBuffering)
	{
		self.state = AudioStreamerStateStopping;
		self.stopReason = AudioStreamerStopReasonError;
		AudioQueueStop(audioQueue, true);
	}
	
	if (self.shouldDisplayAlertOnError)
		[self presentAlertWithTitle:NSLocalizedStringFromTable(@"File Error", @"Errors", nil)
							message:NSLocalizedStringFromTable(@"Unable to configure network read stream.", @"Errors", nil)];
}

//
// mainThreadStateNotification
//
// Method invoked on main thread to send notifications to the main thread's
// notification center.
//
- (void)mainThreadStateNotification
{
	NSNotification *notification =
		[NSNotification
			notificationWithName:ASStatusChangedNotification
			object:self];
	[[NSNotificationCenter defaultCenter]
		postNotification:notification];
}

//
// setState:
//
// Sets the state and sends a notification that the state has changed.
//
// This method
//
// Parameters:
//    aStatus - the current streamer state
//
- (void)setState:(AudioStreamerState)aStatus
{
	if (self.state != aStatus)
	{
		self.lastState = self.state;
		_state = aStatus;
		
		dispatch_async(dispatch_get_main_queue(), ^{
			[self mainThreadStateNotification];
		});
	}
}

//
// isPlaying
//
// returns YES if the audio currently playing.
//
- (BOOL)isPlaying
{
	return (self.state == AudioStreamerStatePlaying);
}

//
// isPaused
//
// returns YES if the audio currently playing.
//
- (BOOL)isPaused
{
	return (self.state == AudioStreamerStatePaused);
}

//
// isBuffering
//
// returns YES if the audio queue is buffering.
//

- (BOOL)isBuffering
{
	return (self.state == AudioStreamerStateBuffering);
}

//
// isWaiting
//
// returns YES if the AudioStreamer is waiting for a state transition of some
// kind.
//
- (BOOL)isWaiting
{
	return ([self isFinishing] ||
			self.state == AudioStreamerStateStartingFileThread||
			self.state == AudioStreamerStateWaitingForData ||
			self.state == AudioStreamerStateWaitingForQueue ||
			self.state == AudioStreamerStateBuffering);
}

//
// isIdle
//
// returns YES if the AudioStream is in the AS_INITIALIZED state (i.e.
// isn't doing anything).
//
- (BOOL)isIdle
{
	return (self.state == AudioStreamerStateInitialized);
}

//
// isAborted
//
// returns YES if the AudioStream was stopped due to some errror, handled through failWithCodeError.
//
- (BOOL)isAborted
{
	return (self.state == AudioStreamerStateStopping && self.stopReason == AudioStreamerStopReasonError);
}

//
// isStopped
//
// returns YES if the AudioStream was stopped for any reason.
//
- (BOOL)isStopped
{
	return (self.state == AudioStreamerStateStopped);
}

//
// hintForFileExtension:
//
// Generates a first guess for the file type based on the file's extension
//
// Parameters:
//    fileExtension - the file extension
//
// returns a file type hint that can be passed to the AudioFileStream
//
+ (AudioFileTypeID)hintForFileExtension:(NSString *)fileExtension
{
	AudioFileTypeID fileTypeHint = kAudioFileAAC_ADTSType;
	
	if ([fileExtension isEqual:@"mp3"])
	{
		fileTypeHint = kAudioFileMP3Type;
	}
	else if ([fileExtension isEqual:@"wav"])
	{
		fileTypeHint = kAudioFileWAVEType;
	}
	else if ([fileExtension isEqual:@"aifc"])
	{
		fileTypeHint = kAudioFileAIFCType;
	}
	else if ([fileExtension isEqual:@"aiff"])
	{
		fileTypeHint = kAudioFileAIFFType;
	}
	else if ([fileExtension isEqual:@"m4a"])
	{
		fileTypeHint = kAudioFileM4AType;
	}
	else if ([fileExtension isEqual:@"mp4"])
	{
		fileTypeHint = kAudioFileMPEG4Type;
	}
	else if ([fileExtension isEqual:@"caf"])
	{
		fileTypeHint = kAudioFileCAFType;
	}
	else if ([fileExtension isEqual:@"aac"])
	{
		fileTypeHint = kAudioFileAAC_ADTSType;
	}
	
	return fileTypeHint;
}

//
// openReadStream
//
// Open the audioFileStream to parse data and the fileHandle as the data
// source.
//
- (BOOL)openReadStream
{
	NSAssert(stream == nil, @"Download stream already initialized");
	
	if (!self.url.isFileURL)
	{
		//
		// Create the HTTP GET request
		//
		CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL, (CFStringRef)@"GET", (__bridge CFURLRef)self.url, kCFHTTPVersion1_1);
		
		//
		// If we are creating this request to seek to a location, set the
		// requested byte range in the headers.
		//
		if (self.fileLength > 0 && seekByteOffset > 0)
		{
			CFHTTPMessageSetHeaderFieldValue(message,
											 CFSTR("Range"),
											 (__bridge CFStringRef)[NSString stringWithFormat:@"bytes=%ld-%ld", (long)seekByteOffset, (long)self.fileLength]);
			discontinuous = YES;
		}
		
		//
		// Create the read stream that will receive data from the HTTP request
		//
		CFReadStreamRef readStream = CFReadStreamCreateForHTTPRequest(NULL, message);
		CFRelease(message);
		
		stream = (__bridge NSInputStream *)readStream;
		CFRelease(readStream);
		
		//
		// Enable stream redirection
		//
		if (CFReadStreamSetProperty(
									(__bridge CFReadStreamRef)stream,
									kCFStreamPropertyHTTPShouldAutoredirect,
									kCFBooleanTrue) == false)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeFileStreamSetPropertyFailed];
			return NO;
		}
		
		//
		// Handle proxies
		//
		CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
		CFReadStreamSetProperty((__bridge CFReadStreamRef)stream, kCFStreamPropertyHTTPProxy, proxySettings);
		CFRelease(proxySettings);
		
		//
		// Handle SSL connections
		//
		if ([[self.url scheme] isEqualToString:@"https"])
		{
			[stream setProperty:NSStreamSocketSecurityLevelNegotiatedSSL forKey:NSStreamSocketSecurityLevelKey];
		}
	}
	else
	{
		stream = [NSInputStream inputStreamWithURL:self.url];
		
		if (!stream)
		{
			return NO;
		}
		
		if (self.fileLength > 0 && seekByteOffset > 0)
		{
			NSLog(@"Setting seek offset property on stream. seekByteOffset: %li", (long)seekByteOffset);
			
			CFNumberRef seekOffset = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &seekByteOffset);
			CFReadStreamSetProperty((__bridge CFReadStreamRef)stream, kCFStreamPropertyFileCurrentOffset, seekOffset);
			CFRelease(seekOffset);
			
			discontinuous = YES;
		}
	}
	
	//
	// We're now ready to receive data
	//
	self.state = AudioStreamerStateWaitingForData;
	
	[stream setDelegate:self];
	[stream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
	[stream open];
	
	return YES;
}

//
// startInternal
//
// This is the start method for the AudioStream thread. This thread is created
// because it will be blocked when there are no audio buffers idle (and ready
// to receive audio data).
//
// Activity in this thread:
//	- Creation and cleanup of all AudioFileStream and AudioQueue objects
//	- Receives data from the CFReadStream
//	- AudioFileStream processing
//	- Copying of data from AudioFileStream into audio buffers
//  - Stopping of the thread because of end-of-file
//	- Stopping due to error or failure
//
// Activity *not* in this thread:
//	- AudioQueue playback and notifications (happens in AudioQueue thread)
//  - Actual download of NSURLConnection data (NSURLConnection's thread)
//	- Creation of the AudioStreamer (other, likely "main" thread)
//	- Invocation of -start method (other, likely "main" thread)
//	- User/manual invocation of -stop (other, likely "main" thread)
//
// This method contains bits of the "main" function from Apple's example in
// AudioFileStreamExample.
//
- (void)startInternal
{
	@autoreleasepool
	{
		if (self.state != AudioStreamerStateStartingFileThread)
		{
			if (self.state != AudioStreamerStateStopping &&
				self.state != AudioStreamerStateStopped)
			{
				NSLog(@"### Not starting audio thread. State code is: %ld", (long)self.state);
			}
			self.state = AudioStreamerStateInitialized;
			return;
		}
		
	#if TARGET_OS_IPHONE			
		//
		// Set the audio session category so that we continue to play if the
		// iPhone/iPod auto-locks.
		//
		NSError *error = nil;
		
		[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
		
		if (error)
		{
			NSLog(@"AudioStreamer problem setting audio category: %@", error.debugDescription);
		}
		else
		{
			[[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
		}
		
		error = nil;
		
		[[AVAudioSession sharedInstance] setActive:YES error:&error];
		
		if (error)
		{
			NSLog(@"AudioStreamer problem setting audio session active: %@", error.debugDescription);
		}
	#endif
	
		// Initialize a semaphore so that we can block on buffers in use.
		bufferSemaphore = dispatch_semaphore_create(0);
		
		if (![self openReadStream])
		{
			[self cleanUp];
		}
		
		//
		// Process the run loop until playback is finished or failed.
		//
		BOOL isRunning = YES;
		
		do
		{
			isRunning = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
												 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
			
			
			if (seekWasRequested)
			{
				[self internalSeekToTime:requestedSeekTime];
				seekWasRequested = NO;
			}
			
			//
			// If there are no queued buffers, we need to check here since the
			// handleBufferCompleteForQueue:buffer: should not change the state
			// (may not enter the synchronized section).
			//
			if (buffersUsed == 0 && self.state == AudioStreamerStatePlaying)
			{
				err = AudioQueuePause(audioQueue);
				
				if (err)
				{
					[self failWithErrorCode:AudioStreamerErrorCodeAudioQueuePauseFailed];
					return;
				}
				
				self.state = AudioStreamerStateBuffering;
			}
			
		} while (isRunning && ![self runLoopShouldExit]);
		
		[self cleanUp];
	}
}

- (void)cleanUp
{
	//
	// Cleanup the read stream if it is still open
	//
	if (stream)
	{
		[stream setDelegate:nil];
		[stream close];
		stream = nil;
	}
	
	//
	// Close the audio file strea,
	//
	if (audioFileStream)
	{
		err = AudioFileStreamClose(audioFileStream);
		audioFileStream = nil;
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeFileStreamCloseFailed];
		}
	}
	
	//
	// Dispose of the Audio Queue
	//
	if (audioQueue)
	{
		err = AudioQueueDispose(audioQueue, true);
		audioQueue = nil;
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueDisposeFailed];
		}
	}
	
	bufferSemaphore = nil;
	
#if TARGET_OS_IPHONE
	NSError *error = nil;
	
	[[AVAudioSession sharedInstance] setActive:NO error:&error];
	
	if (error)
	{
		NSLog(@"AudioStreamer problem setting audio session inactive: %@", error.debugDescription);
	}
#endif
	
	httpHeaders = nil;
	
	bytesFilled = 0;
	packetsFilled = 0;
	seekByteOffset = 0;
	packetBufferSize = 0;
	seekByteOffset = 0;
	seekTime = 0;
	
	self.state = AudioStreamerStateInitialized;
}

//
// start
//
// Calls startInternal in a new thread.
//
- (void)start
{
	if ([self isPaused])
	{
		[self pause];
	}
	else if ([self isIdle])
	{
		NSAssert([[NSThread currentThread] isEqual:[NSThread mainThread]],
			@"Playback can only be started from the main thread.");
		notificationCenter = [NSNotificationCenter defaultCenter];
		self.errorCode = AudioStreamerErrorCodeNone;
		self.state = AudioStreamerStateStartingFileThread;
		
		__weak AudioStreamer *weakSelf = self;
		
		dispatch_async(internalQueue, ^{
			[weakSelf startInternal];
		});
	}
}


// internalSeekToTime:
//
// Called from our internal runloop to reopen the stream at a seeked location
//
- (void)internalSeekToTime:(double)newSeekTime
{
	if ([self calculatedBitRate] == 0.0 || self.fileLength <= 0)
	{
		return;
	}
	
	//
	// Calculate the byte offset for seeking
	//
	seekByteOffset = dataOffset +
		(newSeekTime / self.duration) * (self.fileLength - dataOffset);
		
	//
	// Attempt to leave 1 useful packet at the end of the file (although in
	// reality, this may still seek too far if the file has a long trailer).
	//
	if (seekByteOffset > self.fileLength - 2 * packetBufferSize)
	{
		seekByteOffset = self.fileLength - 2 * packetBufferSize;
	}
	
	//
	// Store the old time from the audio queue and the time that we're seeking
	// to so that we'll know the correct time progress after seeking.
	//
	seekTime = newSeekTime;
	
	//
	// Attempt to align the seek with a packet boundary
	//
	double calculatedBitRate = [self calculatedBitRate];
	
	if (packetDuration > 0 &&
		calculatedBitRate > 0)
	{
		UInt32 ioFlags = 0;
		SInt64 packetAlignedByteOffset;
		SInt64 seekPacket = floor(newSeekTime / packetDuration);
		err = AudioFileStreamSeek(audioFileStream, seekPacket, &packetAlignedByteOffset, &ioFlags);
		
		if (!err && !(ioFlags & kAudioFileStreamSeekFlag_OffsetIsEstimated))
		{
			seekTime -= ((seekByteOffset - dataOffset) - packetAlignedByteOffset) * 8.0 / calculatedBitRate;
			seekByteOffset = packetAlignedByteOffset + dataOffset;
		}
	}

	//
	// Close the current read straem
	//
	if (stream)
	{
		[stream setDelegate: nil];
		[stream close];
		stream = nil;
	}
	
	err = AudioQueueFlush(audioQueue);
	if (err)
	{
		[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueFlushFailed];
		return;
	}

	//
	// Stop the audio queue
	//
	self.state = AudioStreamerStateStopping;
	self.stopReason = AudioStreamerStopReasonTemporary;
	err = AudioQueueStop(audioQueue, true);
	
	if (err)
	{
		[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueStopFailed];
		return;
	}

	//
	// Re-open the file stream. It will request a byte-range starting at
	// seekByteOffset.
	//
	[self openReadStream];
}

//
// seekToTime:
//
// Attempts to seek to the new time. Will be ignored if the bitrate or fileLength
// are unknown.
//
// Parameters:
//    newTime - the time to seek to
//
- (void)seekToTime:(double)newSeekTime
{
	requestedSeekTime = newSeekTime;
	seekWasRequested = YES;
}

//
// progress
//
// returns the current playback progress. Will return zero if sampleRate has
// not yet been detected.
//
- (double)progress
{
	double progress = lastProgress;
	
	if ((sampleRate > 0) &&
		(self.state == AudioStreamerStateStopping || ![self isFinishing]) &&
		audioQueue && stream)
	{
		if (self.state != AudioStreamerStatePlaying &&
			self.state != AudioStreamerStatePaused &&
			self.state != AudioStreamerStateBuffering &&
			self.state != AudioStreamerStateStopping)
		{
			return lastProgress;
		}
		
		AudioTimeStamp queueTime;
		Boolean discontinuity;
		err = AudioQueueGetCurrentTime(audioQueue, NULL, &queueTime, &discontinuity);
		
		const OSStatus AudioQueueStopped = 0x73746F70; // 0x73746F70 is 'stop'
		if (err == AudioQueueStopped)
		{
			return lastProgress;
		}
		else if (err != noErr)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeGetAudioTimeFailed];
		}
		
		progress = seekTime + queueTime.mSampleTime / sampleRate;
		
		if (progress < 0.0)
		{
			progress = 0.0;
		}
		
		lastProgress = progress;
	}
	
	return progress;
}

//
// calculatedBitRate
//
// returns the bit rate, if known. Uses packet duration times running bits per
//   packet if available, otherwise it returns the nominal bitrate. Will return
//   zero if no useful option available.
//
- (double)calculatedBitRate
{
	if (packetDuration && processedPacketsCount > BitRateEstimationMinPackets)
	{
		double averagePacketByteSize = processedPacketsSizeTotal / processedPacketsCount;
		return 8.0 * averagePacketByteSize / packetDuration;
	}
	
	if (bitRate)
	{
		return (double)bitRate;
	}
	
	return 0;
}

//
// duration
//
// Calculates the duration of available audio from the bitRate and fileLength.
//
// returns the calculated duration in seconds.
//
- (double)duration
{
	double calculatedBitRate = [self calculatedBitRate];
	
	if (calculatedBitRate == 0 || self.fileLength == 0)
	{
		return 0.0;
	}
	
	return (self.fileLength - dataOffset) / (calculatedBitRate * 0.125);
}

//
// setPlaybackRate
//
// Modifies the playback rate and applies it to the audio queue if it's available.
//

- (void)setPlaybackRate:(AudioStreamPlaybackRate)rate
{
	if (self.playbackRate != rate)
	{
		_playbackRate = rate;
		
		if (audioQueue)
		{
			err = AudioQueueSetParameter(audioQueue, kAudioQueueParam_PlayRate, [self valueForPlaybackRate:self.playbackRate]);
		}
	}
}

//
// valueForPlaybackRate
//
// Returns a Float64 value for the playback rate specified.
//

- (Float64)valueForPlaybackRate:(AudioStreamPlaybackRate)rate
{
	switch (rate)
	{
		case AudioStreamPlaybackRateHalf:
			return 0.5;
		case AudioStreamPlaybackRateDouble:
			return 1.5;
		case AudioStreamPlaybackRateTriple:
			return 2.0;
		default:
			break;
	}
	
	return 1.0;
}

//
// pause
//
// A togglable pause function.
//
- (void)pause
{
	if (self.state == AudioStreamerStatePlaying || self.state == AudioStreamerStateStopping)
	{
		err = AudioQueuePause(audioQueue);
		
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeAudioQueuePauseFailed];
			return;
		}
		
		self.state = AudioStreamerStatePaused;
	}
	else if (self.state == AudioStreamerStatePaused)
	{
		err = AudioQueueStart(audioQueue, NULL);
		
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueStartFailed];
			return;
		}
		
		self.state = self.lastState;
	}
}

//
// stop
//
// This method can be called to stop downloading/playback before it completes.
// It is automatically called when an error occurs.
//
// If playback has not started before this method is called, it will toggle the
// "isPlaying" property so that it is guaranteed to transition to true and
// back to false 
//
- (void)stop
{
	if (audioQueue &&
		(self.state == AudioStreamerStatePlaying ||
		 self.state == AudioStreamerStatePaused ||
		 self.state == AudioStreamerStateBuffering ||
		 self.state == AudioStreamerStateWaitingForQueue))
	{
		err = AudioQueueFlush(audioQueue);
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueFlushFailed];
			return;
		}
		
		self.state = AudioStreamerStateStopping;
		self.stopReason = AudioStreamerStopReasonUserAction;
		
		err = AudioQueueStop(audioQueue, true);
		
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueStopFailed];
			return;
		}
	}
	else if (![self isIdle])
	{
		self.state = AudioStreamerStateStopped;
		self.stopReason = AudioStreamerStopReasonUserAction;
	}
	
	seekWasRequested = NO;
	
	while (![self isIdle])
	{
		[NSThread sleepForTimeInterval:0.1];
	}
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
	if (![aStream isEqual:stream])
	{
		//
		// Ignore messages from old streams
		//
		return;
	}
	
	switch (eventCode)
	{
		case NSStreamEventHasBytesAvailable:
			[self streamHasBytesAvailable:aStream];
			break;
		case NSStreamEventEndEncountered:
			[self endEncounteredOnStream:aStream];
			break;
		case NSStreamEventErrorOccurred:
			[self failWithErrorCode:AudioStreamerErrorCodeAudioDataNotFound];
			break;
		default:
			break;
	}
}

- (void)streamHasBytesAvailable:(NSStream *)aStream
{
	if (!httpHeaders && !self.url.isFileURL)
	{
		CFTypeRef message = CFReadStreamCopyProperty((__bridge CFReadStreamRef)stream, kCFStreamPropertyHTTPResponseHeader);
		httpHeaders = (__bridge NSDictionary *)CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef)message);
		CFRelease(message);
		
		//
		// Only read the content length if we seeked to time zero, otherwise
		// we only have a subset of the total bytes.
		//
		if (seekByteOffset == 0)
		{
			self.fileLength = [[httpHeaders objectForKey:@"Content-Length"] integerValue];
		}
	}
	
	if (!audioFileStream)
	{
		//
		// Attempt to guess the file type from the URL. Reading the MIME type
		// from the httpHeaders might be a better approach since lots of
		// URL's don't have the right extension.
		//
		// If you have a fixed file-type, you may want to hardcode this.
		//
		if (!self.fileExtension)
		{
			self.fileExtension = (self.url.isFileURL ?
								  [[self.url.lastPathComponent stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] pathExtension] :
								  [[self.url path] pathExtension]);
		}
		AudioFileTypeID fileTypeHint =
		[AudioStreamer hintForFileExtension:self.fileExtension];
		
		// create an audio file stream parser
		err = AudioFileStreamOpen((__bridge void *)(self), ASPropertyListenerProc, ASPacketsProc, fileTypeHint, &audioFileStream);
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeFileStreamOpenFailed];
			return;
		}
	}
	
	UInt8 bytes[kAQDefaultBufSize];
	CFIndex length;
	
	if ([self isFinishing] || ![stream hasBytesAvailable])
	{
		return;
	}
	
	//
	// Read the bytes from the stream
	//
	length = [stream read:bytes maxLength:kAQDefaultBufSize];
	
	if (length == -1)
	{
		[self failWithErrorCode:AudioStreamerErrorCodeAudioDataNotFound];
		return;
	}
	
	if (length == 0)
	{
		return;
	}
	
	if (discontinuous)
	{
		err = AudioFileStreamParseBytes(audioFileStream, (unsigned int)length, bytes, kAudioFileStreamParseFlag_Discontinuity);
		
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeFileStreamParseBytesFailed];
			return;
		}
	}
	else
	{
		err = AudioFileStreamParseBytes(audioFileStream, (unsigned int)length, bytes, 0);
		
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeFileStreamParseBytesFailed];
			return;
		}
	}
}

- (void)endEncounteredOnStream:(NSStream *)aStream
{
	if ([self isFinishing])
	{
		return;
	}
	
	//
	// If there is a partially filled buffer, pass it to the AudioQueue for
	// processing
	//
	if (bytesFilled)
	{
		if (self.state == AudioStreamerStateWaitingForData)
		{
			//
			// Force audio data smaller than one whole buffer to play.
			//
			self.state = AudioStreamerStateEOF;
		}
		
		[self enqueueBuffer];
	}
	
	if (self.state == AudioStreamerStateWaitingForData)
	{
		[self failWithErrorCode:AudioStreamerErrorCodeAudioDataNotFound];
	}
	
	//
	// We left the synchronized section to enqueue the buffer so we
	// must check that we are !finished again before touching the
	// audioQueue
	//
	else if (![self isFinishing])
	{
		if (audioQueue)
		{
			self.state = AudioStreamerStateStopping;
			self.stopReason = AudioStreamerStopReasonEOF;
			
			err = AudioQueueStop(audioQueue, false);
			
			if (err)
			{
				[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueFlushFailed];
				return;
			}
		}
		else
		{
			self.state = AudioStreamerStateStopped;
			self.stopReason = AudioStreamerStopReasonEOF;
		}
	}
}

//
// enqueueBuffer
//
// Called from ASPacketsProc and connectionDidFinishLoading to pass filled audio
// bufffers (filled by ASPacketsProc) to the AudioQueue for playback. This
// function does not return until a buffer is idle for further filling or
// the AudioQueue is stopped.
//
// This function is adapted from Apple's example in AudioFileStreamExample with
// CBR functionality added.
//
- (void)enqueueBuffer
{
	if ([self isFinishing] || stream == 0)
	{
		return;
	}
	
	inuse[fillBufferIndex] = true;		// set in use flag
	buffersUsed++;
	
	// enqueue buffer
	AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
	fillBuf->mAudioDataByteSize = (UInt32)bytesFilled;
	
	if (packetsFilled)
	{
		err = AudioQueueEnqueueBuffer(audioQueue, fillBuf, (UInt32)packetsFilled, packetDescs);
	}
	else
	{
		err = AudioQueueEnqueueBuffer(audioQueue, fillBuf, 0, NULL);
	}
	
	if (err)
	{
		[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueEnqueueFailed];
		return;
	}
	
	if (self.state == AudioStreamerStateBuffering ||
		self.state == AudioStreamerStateWaitingForData ||
		self.state == AudioStreamerStateEOF ||
		(self.state == AudioStreamerStateStopped && self.stopReason == AudioStreamerStopReasonTemporary))
	{
		//
		// Fill all the buffers before starting. This ensures that the
		// AudioFileStream stays a small amount ahead of the AudioQueue to
		// avoid an audio glitch playing streaming files on iPhone SDKs < 3.0
		//
		if (self.state == AudioStreamerStateEOF || buffersUsed == kNumAQBufs - 1)
		{
			if (self.state == AudioStreamerStateBuffering)
			{
				if (self.shouldStartPaused)
				{
					self.state = AudioStreamerStatePaused;
					self.shouldStartPaused = NO;
					
					return;
				}
				
				err = AudioQueueStart(audioQueue, NULL);
				
				if (err)
				{
					[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueStartFailed];
					return;
				}
				
				self.state = AudioStreamerStatePlaying;
			}
			else
			{
				self.state = AudioStreamerStateWaitingForQueue;
				
				err = AudioQueueStart(audioQueue, NULL);
				
				if (err)
				{
					[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueStartFailed];
					return;
				}
			}
		}
	}
	
	// go to next buffer
	if (++fillBufferIndex >= kNumAQBufs) fillBufferIndex = 0;
	bytesFilled = 0;		// reset bytes filled
	packetsFilled = 0;		// reset packets filled
	
	// wait until next buffer is not in use
	while (inuse[fillBufferIndex])
	{
		dispatch_semaphore_wait(bufferSemaphore, DISPATCH_TIME_FOREVER);
	}
}

//
// createQueue
//
// Method to create the AudioQueue from the parameters gathered by the
// AudioFileStream.
//
// Creation is deferred to the handling of the first audio packet (although
// it could be handled any time after kAudioFileStreamProperty_ReadyToProducePackets
// is true).
//
- (void)createQueue
{
	sampleRate = asbd.mSampleRate;
	packetDuration = asbd.mFramesPerPacket / sampleRate;
	
	// create the audio queue
	err = AudioQueueNewOutput(&asbd, ASAudioQueueOutputCallback, (__bridge void *)(self), NULL, NULL, 0, &audioQueue);
	
	if (err)
	{
		[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueCreationFailed];
		return;
	}
	
	// start the queue if it has not been started already
	// listen to the "isRunning" property
	err = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, ASAudioQueueIsRunningCallback, (__bridge void *)(self));
	
	if (err)
	{
		[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueAddListenerFailed];
		return;
	}
	
	// get the packet size if it is available
	UInt32 sizeOfUInt32 = sizeof(UInt32);
	
	err = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfUInt32, &packetBufferSize);
	
	if (err || packetBufferSize == 0)
	{
		err = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfUInt32, &packetBufferSize);
		
		if (err || packetBufferSize == 0)
		{
			// No packet size available, just use the default
			packetBufferSize = kAQDefaultBufSize;
		}
	}
	
	UInt32 enableTimePitch = 1;
	
	err = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_EnableTimePitch, &enableTimePitch, sizeof(UInt32));
	
	if (err == noErr)
	{
		UInt32 propValue = (self.mediaType == AudioStreamMediaTypeMusic ?
							kAudioQueueTimePitchAlgorithm_LowQualityZeroLatency :
							kAudioQueueTimePitchAlgorithm_Spectral);
		
		err = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_TimePitchAlgorithm, &propValue, sizeof(UInt32));
		
		if (err == noErr)
		{
			propValue = 0;
			
			err = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_TimePitchBypass, &propValue, sizeof(propValue));
			
			if (err == noErr)
			{
				err = AudioQueueSetParameter(audioQueue, kAudioQueueParam_PlayRate, [self valueForPlaybackRate:self.playbackRate]);
			}
		}
	}

	// allocate audio queue buffers
	for (unsigned int i = 0; i < kNumAQBufs; ++i)
	{
		err = AudioQueueAllocateBuffer(audioQueue, packetBufferSize, &audioQueueBuffer[i]);
		
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueBufferAllocationFailed];
			return;
		}
	}

	// get the cookie size
	UInt32 cookieSize;
	Boolean writable;
	OSStatus ignorableError = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
	
	if (ignorableError)
	{
		return;
	}

	// get the cookie data
	void* cookieData = calloc(1, cookieSize);
	ignorableError = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
	
	if (ignorableError)
	{
		return;
	}

	// set the cookie on the queue.
	ignorableError = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
	free(cookieData);
}

//
// handlePropertyChangeForFileStream:fileStreamPropertyID:ioFlags:
//
// Object method which handles implementation of ASPropertyListenerProc
//
// Parameters:
//    inAudioFileStream - should be the same as self->audioFileStream
//    inPropertyID - the property that changed
//    ioFlags - the ioFlags passed in
//
- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
	fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
	ioFlags:(UInt32 *)ioFlags
{
	if ([self isFinishing])
	{
		return;
	}
	
	if (inPropertyID == kAudioFileStreamProperty_ReadyToProducePackets)
	{
		discontinuous = true;
	}
	else if (inPropertyID == kAudioFileStreamProperty_DataOffset)
	{
		SInt64 offset;
		UInt32 offsetSize = sizeof(offset);
		err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset);
		
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeFileStreamGetPropertyFailed];
			return;
		}
		
		dataOffset = offset;
		
		if (audioDataByteCount)
		{
			self.fileLength = dataOffset + audioDataByteCount;
		}
	}
	else if (inPropertyID == kAudioFileStreamProperty_AudioDataByteCount)
	{
		UInt32 byteCountSize = sizeof(UInt64);
		
		err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &audioDataByteCount);
		
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeFileStreamGetPropertyFailed];
			return;
		}
		
		self.fileLength = dataOffset + audioDataByteCount;
	}
	else if (inPropertyID == kAudioFileStreamProperty_DataFormat)
	{
		if (asbd.mSampleRate == 0)
		{
			UInt32 asbdSize = sizeof(asbd);
			
			// get the stream format.
			err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &asbdSize, &asbd);
			
			if (err)
			{
				[self failWithErrorCode:AudioStreamerErrorCodeFileStreamGetPropertyFailed];
				return;
			}
		}
	}
	else if (inPropertyID == kAudioFileStreamProperty_FormatList)
	{
		Boolean outWriteable;
		UInt32 formatListSize;
		
		err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
		
		if (err)
		{
			[self failWithErrorCode:AudioStreamerErrorCodeFileStreamGetPropertyFailed];
			return;
		}
		
		AudioFormatListItem *formatList = malloc(formatListSize);
		err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
		
		if (err)
		{
			free(formatList);
			[self failWithErrorCode:AudioStreamerErrorCodeFileStreamGetPropertyFailed];
			return;
		}

		for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
		{
			AudioStreamBasicDescription pasbd = formatList[i].mASBD;
	
			if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE ||
				pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
			{
				//
				// We've found HE-AAC, remember this to tell the audio queue
				// when we construct it.
				//
#if !TARGET_IPHONE_SIMULATOR
				asbd = pasbd;
#endif
				break;
			}                                
		}
		
		free(formatList);
	}
	else
	{
//			NSLog(@"Property is %c%c%c%c",
//				((char *)&inPropertyID)[3],
//				((char *)&inPropertyID)[2],
//				((char *)&inPropertyID)[1],
//				((char *)&inPropertyID)[0]);
	}
}

//
// handleAudioPackets:numberBytes:numberPackets:packetDescriptions:
//
// Object method which handles the implementation of ASPacketsProc
//
// Parameters:
//    inInputData - the packet data
//    inNumberBytes - byte size of the data
//    inNumberPackets - number of packets in the data
//    inPacketDescriptions - packet descriptions
//
- (void)handleAudioPackets:(const void *)inInputData
	numberBytes:(UInt32)inNumberBytes
	numberPackets:(UInt32)inNumberPackets
	packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions;
{
	if ([self isFinishing])
	{
		return;
	}
	
	if (bitRate == 0)
	{
		//
		// m4a and a few other formats refuse to parse the bitrate so
		// we need to set an "unparseable" condition here. If you know
		// the bitrate (parsed it another way) you can set it on the
		// class if needed.
		//
		bitRate = ~0;
	}
	
	// we have successfully read the first packests from the audio stream, so
	// clear the "discontinuous" flag
	if (discontinuous)
	{
		discontinuous = false;
	}
	
	if (!audioQueue)
	{
		[self createQueue];
	}
	
	// the following code assumes we're streaming VBR data. for CBR data, the second branch is used.
	if (inPacketDescriptions)
	{
		for (int i = 0; i < inNumberPackets; ++i)
		{
			SInt64 packetOffset = inPacketDescriptions[i].mStartOffset;
			SInt64 packetSize   = inPacketDescriptions[i].mDataByteSize;
			__block size_t bufSpaceRemaining;
			
			if (processedPacketsCount < BitRateEstimationMaxPackets)
			{
				processedPacketsSizeTotal += packetSize;
				processedPacketsCount += 1;
			}
			
			// If the audio was terminated before this point, then
			// exit.
			if ([self isFinishing])
			{
				return;
			}
			
			if (packetSize > packetBufferSize)
			{
				[self failWithErrorCode:AudioStreamerErrorCodeAudioBufferTooSmall];
			}

			bufSpaceRemaining = packetBufferSize - bytesFilled;
			
			// if the space remaining in the buffer is not enough for this packet, then enqueue the buffer.
			if (bufSpaceRemaining < packetSize)
			{
				[self enqueueBuffer];
			}
			
			// If the audio was terminated while waiting for a buffer, then
			// exit.
			if ([self isFinishing])
			{
				return;
			}
			
			//
			// If there was some kind of issue with enqueueBuffer and we didn't
			// make space for the new audio data then back out
			//
			if ((long long)bytesFilled + packetSize > packetBufferSize)
			{
				return;
			}
			
			// copy data to the audio queue buffer
			AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
			memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)inInputData + packetOffset, packetSize);

			// fill out packet description
			packetDescs[packetsFilled] = inPacketDescriptions[i];
			packetDescs[packetsFilled].mStartOffset = bytesFilled;
			// keep track of bytes filled and packets filled
			bytesFilled += packetSize;
			packetsFilled += 1;
			
			// if that was the last free packet description, then enqueue the buffer.
			size_t packetsDescsRemaining = kAQMaxPacketDescs - packetsFilled;
			
			if (packetsDescsRemaining == 0)
			{
				[self enqueueBuffer];
			}
		}	
	}
	else
	{
		__block size_t offset = 0;
		__block UInt32 numberBytes = inNumberBytes;
		while (numberBytes)
		{
			// if the space remaining in the buffer is not enough for this packet, then enqueue the buffer.
			__block size_t bufSpaceRemaining = kAQDefaultBufSize - bytesFilled;
			
			if (bufSpaceRemaining < inNumberBytes)
			{
				[self enqueueBuffer];
			}
			
			// If the audio was terminated while waiting for a buffer, then
			// exit.
			if ([self isFinishing])
			{
				return;
			}
			
			bufSpaceRemaining = kAQDefaultBufSize - bytesFilled;
			size_t copySize;
			
			if (bufSpaceRemaining < inNumberBytes)
			{
				copySize = bufSpaceRemaining;
			}
			else
			{
				copySize = inNumberBytes;
			}

			//
			// If there was some kind of issue with enqueueBuffer and we didn't
			// make space for the new audio data then back out
			//
			if (bytesFilled > packetBufferSize)
			{
				return;
			}
			
			// copy data to the audio queue buffer
			AudioQueueBufferRef fillBuf = audioQueueBuffer[fillBufferIndex];
			memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)(inInputData + offset), copySize);


			// keep track of bytes filled and packets filled
			bytesFilled += copySize;
			packetsFilled = 0;
			numberBytes -= copySize;
			offset += copySize;
		}
	}
}

//
// handleBufferCompleteForQueue:buffer:
//
// Handles the buffer completetion notification from the audio queue
//
// Parameters:
//    inAQ - the queue
//    inBuffer - the buffer
//
- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ
	buffer:(AudioQueueBufferRef)inBuffer
{
	unsigned int bufIndex = -1;
	for (unsigned int i = 0; i < kNumAQBufs; ++i)
	{
		if (inBuffer == audioQueueBuffer[i])
		{
			bufIndex = i;
			break;
		}
	}
	
	if (bufIndex == -1)
	{
		[self failWithErrorCode:AudioStreamerErrorCodeAudioQueueBufferMismatch];
		dispatch_semaphore_signal(bufferSemaphore);
		return;
	}
	
	// Signal waiting thread that the buffer is free.
	inuse[bufIndex] = false;
	buffersUsed--;

//
//  Enable this logging to measure how many buffers are queued at any time.
//
#if LOG_QUEUED_BUFFERS
	NSLog(@"Queued buffers: %ld", buffersUsed);
#endif
	
	dispatch_semaphore_signal(bufferSemaphore);
}

- (void)handlePropertyChange:(NSNumber *)num
{
	[self handlePropertyChangeForQueue:NULL propertyID:[num intValue]];
}

//
// handlePropertyChangeForQueue:propertyID:
//
// Implementation for ASAudioQueueIsRunningCallback
//
// Parameters:
//    inAQ - the audio queue
//    inID - the property ID
//
- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ
	propertyID:(AudioQueuePropertyID)inID
{
	@autoreleasepool
	{
		if ([NSThread isMainThread])
		{
			__weak AudioStreamer *weakSelf = self;
			
			dispatch_async(internalQueue, ^{
				[weakSelf handlePropertyChange:@(inID)];
			});
		}
		
		if (inID == kAudioQueueProperty_IsRunning)
		{
			if (self.state == AudioStreamerStateStopping)
			{
				// Should check value of isRunning to ensure this kAudioQueueProperty_IsRunning isn't
				// the *start* of a very short stream
				UInt32 isRunning = 0;
				UInt32 size = sizeof(UInt32);
				AudioQueueGetProperty(audioQueue, inID, &isRunning, &size);
				
				if (isRunning == 0)
				{
					self.state = AudioStreamerStateStopped;
				}
			}
			else if (self.state == AudioStreamerStateWaitingForQueue)
			{
				//
				// Note about this bug avoidance quirk:
				//
				// On cleanup of the AudioQueue thread, on rare occasions, there would
				// be a crash in CFSetContainsValue as a CFRunLoopObserver was getting
				// removed from the CFRunLoop.
				//
				// After lots of testing, it appeared that the audio thread was
				// attempting to remove CFRunLoop observers from the CFRunLoop after the
				// thread had already deallocated the run loop.
				//
				// By creating an NSRunLoop for the AudioQueue thread, it changes the
				// thread destruction order and seems to avoid this crash bug -- or
				// at least I haven't had it since (nasty hard to reproduce error!)
				//
				[NSRunLoop currentRunLoop];
				
				self.state = AudioStreamerStatePlaying;
				
				if (self.shouldStartPaused)
				{
					[self pause];
					self.shouldStartPaused = NO;
					
					return;
				}
			}
			else
			{
				NSLog(@"AudioQueue changed state in unexpected way.");
			}
		}
	}
}

#if TARGET_OS_IPHONE
//
// handleInterruptionChangeForQueue:propertyID:
//
// Implementation for ASAudioQueueInterruptionListener
//
// Parameters:
//    inAQ - the audio queue
//    inID - the property ID
//
- (void)handleInterruptionChangeToState:(NSNotification *)notification {
	
	AVAudioSessionInterruptionType interruptionType = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
	AVAudioSessionInterruptionOptions options = [notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
	
	if (interruptionType == AVAudioSessionInterruptionTypeBegan)
	{ 
		if ([self isPlaying]) {
			[self pause];
			
			pausedByInterruption = YES; 
		} 
	}
	else if (interruptionType == AVAudioSessionInterruptionTypeEnded)
	{
		if (options == AVAudioSessionInterruptionOptionShouldResume)
		{
			NSError *error = nil;
			
			[[AVAudioSession sharedInstance] setActive:YES error:&error];
			
			if (error)
			{
				NSLog(@"AudioStreamer error while setting session to active. ERROR: %@", error.localizedDescription);
			}
			
			if ([self isPaused] && pausedByInterruption) {
				[self pause]; // this is actually resume
				
				pausedByInterruption = NO; // this is redundant
			}
		}
	}
}
#endif

@end


