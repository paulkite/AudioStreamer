//
//  AudioStreamer.h
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

#if TARGET_OS_IPHONE			
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif // TARGET_OS_IPHONE

#include <pthread.h>
#include <AudioToolbox/AudioToolbox.h>

#define LOG_QUEUED_BUFFERS 0

#define kNumAQBufs 16			// Number of audio queue buffers we allocate.
								// Needs to be big enough to keep audio pipeline
								// busy (non-zero number of queued buffers) but
								// not so big that audio takes too long to begin
								// (kNumAQBufs * kAQBufSize of data must be
								// loaded before playback will start).
								//
								// Set LOG_QUEUED_BUFFERS to 1 to log how many
								// buffers are queued at any time -- if it drops
								// to zero too often, this value may need to
								// increase. Min 3, typical 8-24.
								
#define kAQDefaultBufSize 2048	// Number of bytes in each audio queue buffer
								// Needs to be big enough to hold a packet of
								// audio from the audio file. If number is too
								// large, queuing of audio before playback starts
								// will take too long.
								// Highly compressed files can use smaller
								// numbers (512 or less). 2048 should hold all
								// but the largest packets. A buffer size error
								// will occur if this number is too small.

#define kAQMaxPacketDescs 512	// Number of packet descriptions in our array

typedef NS_ENUM(NSUInteger, AudioStreamerState)
{
	AudioStreamerStateInitialized = 0,
	AudioStreamerStateStartingFileThread,
	AudioStreamerStateWaitingForData,
	AudioStreamerStateEOF,
	AudioStreamerStateWaitingForQueue,
	AudioStreamerStatePlaying,
	AudioStreamerStateBuffering,
	AudioStreamerStateStopping,
	AudioStreamerStateStopped,
	AudioStreamerStatePaused
};

typedef NS_ENUM(NSUInteger, AudioStreamerStopReason)
{
	AudioStreamerStopReasonNone = 0,
	AudioStreamerStopReasonEOF,
	AudioStreamerStopReasonUserAction,
	AudioStreamerStopReasonError,
	AudioStreamerStopReasonTemporary
};

typedef NS_ENUM(NSUInteger, AudioStreamerErrorCode)
{
	AudioStreamerErrorCodeNone = 0,
	AudioStreamerErrorCodeNetworkConnectionFailed,
	AudioStreamerErrorCodeFileStreamGetPropertyFailed,
	AudioStreamerErrorCodeFileStreamSetPropertyFailed,
	AudioStreamerErrorCodeFileStreamSeekFailed,
	AudioStreamerErrorCodeFileStreamParseBytesFailed,
	AudioStreamerErrorCodeFileStreamOpenFailed,
	AudioStreamerErrorCodeFileStreamCloseFailed,
	AudioStreamerErrorCodeAudioDataNotFound,
	AudioStreamerErrorCodeAudioQueueCreationFailed,
	AudioStreamerErrorCodeAudioQueueBufferAllocationFailed,
	AudioStreamerErrorCodeAudioQueueEnqueueFailed,
	AudioStreamerErrorCodeAudioQueueAddListenerFailed,
	AudioStreamerErrorCodeAudioQueueRemoveListenerFailed,
	AudioStreamerErrorCodeAudioQueueStartFailed,
	AudioStreamerErrorCodeAudioQueuePauseFailed,
	AudioStreamerErrorCodeAudioQueueBufferMismatch,
	AudioStreamerErrorCodeAudioQueueDisposeFailed,
	AudioStreamerErrorCodeAudioQueueStopFailed,
	AudioStreamerErrorCodeAudioQueueFlushFailed,
	AudioStreamerErrorCodeAudioStreamerFailed,
	AudioStreamerErrorCodeGetAudioTimeFailed,
	AudioStreamerErrorCodeAudioBufferTooSmall,
	AudioStreamerErrorCodeSocketConnectionFailed,
	AudioStreamerErrorCodeSSLAuthorizationFailed
};

typedef NS_ENUM(NSUInteger, AudioStreamMediaType)
{
	AudioStreamMediaTypeMusic = 0,
	AudioStreamMediaTypeSpokenWord
};

typedef NS_ENUM(NSUInteger, AudioStreamPlaybackRate)
{
	AudioStreamPlaybackRateHalf = 0,
	AudioStreamPlaybackRateNormal,
	AudioStreamPlaybackRateDouble,
	AudioStreamPlaybackRateTriple
};

typedef NS_ENUM(NSUInteger, AudioStreamerResourceType)
{
	AudioStreamerResourceTypeNotSet = 0,
	AudioStreamerResourceTypeNetwork,
	AudioStreamerResourceTypeFileOnDisk
};

extern NSString * const ASStatusChangedNotification;

@protocol AudioStreamerDelegate;

@interface AudioStreamer : NSObject
{
	//
	// Special threading consideration:
	//	The audioQueue property should only ever be accessed inside a
	//	synchronized(self) block and only *after* checking that ![self isFinishing]
	//
	AudioQueueRef audioQueue;
	AudioFileStreamID audioFileStream;	// the audio file stream parser
	AudioStreamBasicDescription asbd;	// description of the audio
	
	AudioQueueBufferRef audioQueueBuffer[kNumAQBufs];		// audio queue buffers
	AudioStreamPacketDescription packetDescs[kAQMaxPacketDescs];	// packet descriptions for enqueuing audio
	unsigned int fillBufferIndex;	// the index of the audioQueueBuffer that is being filled
	UInt32 packetBufferSize;
	size_t bytesFilled;				// how many bytes have been filled
	size_t packetsFilled;			// how many packets have been filled
	bool inuse[kNumAQBufs];			// flags to indicate that a buffer is still in use
	NSInteger buffersUsed;
	
	OSStatus err;
	
	bool discontinuous;			// flag to indicate middle of the stream
	
	UInt32 bitRate;				// Bits per second in the file
	NSInteger dataOffset;		// Offset of the first audio packet in the stream
	NSInteger seekByteOffset;	// Seek offset within the file in bytes
	UInt64 audioDataByteCount;  // Used when the actual number of audio bytes in
								// the file is known (more accurate than assuming
								// the whole file is audio)

	UInt64 processedPacketsCount;		// number of packets accumulated for bitrate estimation
	UInt64 processedPacketsSizeTotal;	// byte size of accumulated estimation packets

	double seekTime;
	BOOL seekWasRequested;
	double requestedSeekTime;
	double sampleRate;			// Sample rate of the file (used to compare with
								// samples played by the queue for current playback
								// time)
	double packetDuration;		// sample rate times frames per packet
	double lastProgress;		// last calculated progress point
#if TARGET_OS_IPHONE
	BOOL pausedByInterruption;
#endif
}

@property (nonatomic, weak, readwrite) id<AudioStreamerDelegate> delegate;
@property (nonatomic, assign, readonly) AudioStreamerErrorCode errorCode;
@property (nonatomic, assign, readwrite) NSInteger fileLength; // Length of the file in bytes
@property (nonatomic, assign, readonly) AudioStreamerState lastState;
@property (nonatomic, assign, readwrite) AudioStreamMediaType mediaType;
@property (nonatomic, assign, readwrite) AudioStreamPlaybackRate playbackRate;
@property (nonatomic, assign, readonly) AudioStreamerState state;
@property (nonatomic, assign, readwrite) BOOL shouldStartPaused;
@property (nonatomic, assign, readonly) AudioStreamerStopReason stopReason;
@property (nonatomic, assign, readonly) NSInteger cacheBytesRead;
@property (nonatomic, assign, readwrite) NSInteger cacheBytesProgress;
@property (readonly) double progress;
@property (readonly) double duration;
@property (readwrite) UInt32 bitRate;

+ (AudioFileTypeID)hintForFileExtension:(NSString *)fileExtension;
+ (AudioFileTypeID)hintForMIMEType:(NSString *)mimeType;

- (NSURL *)url;
- (void)start;
- (void)stop;
- (void)pause;
- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isBuffering;
- (BOOL)isWaiting;
- (BOOL)isIdle;
- (BOOL)isAborted; // return YES if streaming halted due to error (AudioStreamerStateStopping + AudioStreamerStopReasonError)
- (BOOL)isStopped;
- (void)seekToTime:(double)newSeekTime;
- (double)calculatedBitRate;

@end

@protocol AudioStreamerDelegate <NSObject>

- (NSURLRequest *)URLRequestForCurrentPlayableItemWithResourceType:(AudioStreamerResourceType)resourceType;
- (NSURLSessionConfiguration *)sessionConfigurationForAudioStreamer:(AudioStreamer *)streamer;

@end





