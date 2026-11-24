// SGFluidClip.h says what this draws. The blurred field is drawn small and scaled up, since it has no
// detail to lose, and the cover is drawn once with its shadow and laid on each frame, so a frame costs two
// image draws at the clip's size and an encode.
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import "SGFluidClip.h"

// Each copy, as in SGRFluid.m: its side as a share of the clip's longer side, its center as shares of the
// clip, its opacity, and its resting angle. Over the loop it sways by kSway either side of that angle and
// its center circles kDrift of the clip, a quarter cycle after the copy before it.
static const struct { CGFloat side, x, y, opacity, angle; } kCopy[] = {
    {2.2, 0.25, 0.20, 1.0, 0.0},
    {2.0, 0.80, 0.35, 0.7, 1.1},
    {2.4, 0.30, 0.75, 0.7, 2.3},
    {1.8, 0.70, 0.85, 0.7, 4.0},
};
enum { kCopies = sizeof(kCopy) / sizeof(kCopy[0]) };
static const CGFloat kSway = 0.35, kDrift = 0.06;
// The blurred cover is small, as in SGRFluid.m, and the field is drawn at this fraction of the clip's size.
static const CGFloat kBlurSide = 128, kBlurRadius = 10, kSaturation = 1.5, kBrightness = -0.08, kFieldScale = 0.125;
// The shade over the bottom, where the lock screen's controls are.
static const CGFloat kShadeFrom = 0.55, kShadeAlpha = 0.45;
// The cover's side as a share of the clip's width, and its center's height from the top. The lock screen
// cuts a 3:4 clip's sides off on a phone's taller screen, so the cover keeps to the middle.
// ponytail: guessed from the screen's shape, as SGLyricsClip.m's column is; tune both on a device.
static const CGFloat kCoverSide = 0.5, kCoverY = 0.45, kCoverRadius = 0.035, kShadowBlur = 0.08;
// An eight second loop: long enough that the sway reads as slow, short enough to write in a few seconds.
static const int32_t kLoopSeconds = 8, kFPS = 24;

static CGContextRef newContext(CGSize size, void *data, size_t bytesPerRow) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(data, (size_t)size.width, (size_t)size.height, 8, bytesPerRow, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    return context;
}

// The cover small, blurred and saturated, as SGRFluid.m makes it.
static CGImageRef newBlurred(CGImageRef cover) CF_RETURNS_RETAINED {
    static CIContext *renderer;
    static dispatch_once_t once;
    // On the CPU: the lock screen asks while Spotify is in the background, where GPU work gets it killed.
    dispatch_once(&once, ^{ renderer = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}]; });
    CIImage *input = [CIImage imageWithCGImage:cover];
    CGFloat scale = kBlurSide / MAX(input.extent.size.width, input.extent.size.height);
    input = [input imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect extent = input.extent;
    CIImage *output = [[[input imageByClampingToExtent]
        imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(kBlurRadius)}]
        imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputSaturationKey: @(kSaturation), kCIInputBrightnessKey: @(kBrightness)}];
    return [renderer createCGImage:[output imageByCroppingToRect:extent] fromRect:extent];
}

// Where the cover's picture goes with its shadow around it: the frame of the image newCover makes.
static CGRect coverFrame(CGSize size) {
    CGFloat side = round(size.width * kCoverSide), margin = ceil(side * kShadowBlur * 1.5);
    CGFloat x = round((size.width - side) / 2), top = round(size.height * kCoverY - side / 2);
    // Core Graphics counts up from the bottom.
    return CGRectMake(x - margin, size.height - top - side - margin, side + 2 * margin, side + 2 * margin);
}

// The cover with its rounded corners and a soft shadow, on a clear image the size of coverFrame.
static CGImageRef newCover(CGImageRef cover, CGSize size) CF_RETURNS_RETAINED {
    CGRect frame = coverFrame(size);
    CGFloat side = round(size.width * kCoverSide), margin = (frame.size.width - side) / 2;
    CGContextRef context = newContext(frame.size, NULL, 0);
    CGRect picture = CGRectMake(margin, margin, side, side);
    CGPathRef rounded = CGPathCreateWithRoundedRect(picture, side * kCoverRadius, side * kCoverRadius, NULL);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat shade[] = {0, 0, 0, 0.5};
    CGColorRef shadow = CGColorCreate(space, shade);
    CGContextSaveGState(context);
    CGContextSetShadowWithColor(context, CGSizeMake(0, -side * 0.02), side * kShadowBlur, shadow);
    CGContextAddPath(context, rounded);
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillPath(context);
    CGContextRestoreGState(context);
    CGContextAddPath(context, rounded);
    CGContextClip(context);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    // Filled, should the cover not be square.
    CGFloat width = CGImageGetWidth(cover), height = CGImageGetHeight(cover);
    CGFloat scale = MAX(side / MAX(width, 1), side / MAX(height, 1));
    CGContextDrawImage(context, CGRectMake(margin + (side - width * scale) / 2, margin + (side - height * scale) / 2, width * scale, height * scale), cover);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGPathRelease(rounded);
    CGColorRelease(shadow);
    CGColorSpaceRelease(space);
    return image;
}

typedef struct {
    CGImageRef blurred, cover;
    CGContextRef field;   // the small canvas the field is drawn on
    CGSize fieldSize;
    CGGradientRef shade;
} Parts;

static Parts makeParts(CGImageRef cover, CGSize size) {
    Parts parts = {0};
    parts.blurred = newBlurred(cover);
    parts.cover = newCover(cover, size);
    parts.fieldSize = CGSizeMake(ceil(size.width * kFieldScale), ceil(size.height * kFieldScale));
    parts.field = newContext(parts.fieldSize, NULL, 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat colors[] = {0, 0, 0, 0, 0, 0, 0, kShadeAlpha}, locations[] = {0, 1};
    parts.shade = CGGradientCreateWithColorComponents(space, colors, locations, 2);
    CGColorSpaceRelease(space);
    return parts;
}

static void freeParts(Parts parts) {
    CGImageRelease(parts.blurred);
    CGImageRelease(parts.cover);
    CGContextRelease(parts.field);
    CGGradientRelease(parts.shade);
}

// A frame `phase` of the way through the loop, 0 to 1, into `context`.
static void drawFrame(CGContextRef context, Parts parts, CGSize size, double phase) {
    CGContextRef field = parts.field;
    CGSize small = parts.fieldSize;
    CGFloat longer = MAX(small.width, small.height);
    CGContextSetRGBFillColor(field, 0, 0, 0, 1);
    CGContextFillRect(field, (CGRect){CGPointZero, small});
    CGContextSetInterpolationQuality(field, kCGInterpolationMedium);
    for (int i = 0; i < kCopies; i++) {
        double turn = 2 * M_PI * phase + i * M_PI_2;
        CGFloat side = longer * kCopy[i].side;
        CGFloat x = small.width * (kCopy[i].x + kDrift * cos(turn)), y = small.height * (1 - kCopy[i].y + kDrift * sin(turn));
        CGContextSaveGState(field);
        CGContextSetAlpha(field, kCopy[i].opacity);
        CGContextTranslateCTM(field, x, y);
        CGContextRotateCTM(field, kCopy[i].angle + (i % 2 ? -kSway : kSway) * sin(turn));
        CGContextDrawImage(field, CGRectMake(-side / 2, -side / 2, side, side), parts.blurred);
        CGContextRestoreGState(field);
    }
    // From kShadeFrom of the way down to the bottom, which Core Graphics counts up from.
    CGContextDrawLinearGradient(field, parts.shade, CGPointMake(0, small.height * (1 - kShadeFrom)), CGPointZero,
                                kCGGradientDrawsAfterEndLocation);
    CGImageRef drawn = CGBitmapContextCreateImage(field);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, (CGRect){CGPointZero, size}, drawn);
    CGImageRelease(drawn);
    CGContextDrawImage(context, coverFrame(size), parts.cover);
}

CGImageRef SGFluidClipFrame(CGImageRef cover, CGSize size) {
    if (!cover) return NULL;
    Parts parts = makeParts(cover, size);
    CGContextRef context = newContext(size, NULL, 0);
    drawFrame(context, parts, size, 0);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    freeParts(parts);
    return frame;
}

// ponytail: the writing loop is SGLyricsClip.m's again, kept apart so neither clip's drawing leaks into the
// other's; one writer taking a draw block is the step up if a third clip comes.
BOOL SGFluidClipWrite(NSURL *file, CGImageRef cover, CGSize size) {
    if (!cover) return NO;
    // Written beside the file and moved over it once whole, so a clip cut off halfway is never found.
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) return NO;
    int32_t frames = kLoopSeconds * kFPS;
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(2000000), AVVideoMaxKeyFrameIntervalKey: @(kFPS)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
        }];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    Parts parts = makeParts(cover, size);
    BOOL ok = parts.blurred && parts.cover;
    for (int32_t i = 0; i < frames && ok; i++) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
        CVPixelBufferRef buffer = NULL;
        ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
            && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
        if (!ok) break;
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = newContext(size, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        drawFrame(context, parts, size, (double)i / frames);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        ok = [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(i, kFPS)];
        CVPixelBufferRelease(buffer);
    }
    freeParts(parts);
    if (!ok) {
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake(kLoopSeconds, 1)];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) return NO;
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}

#pragma mark - the cover alone

CGImageRef SGCoverClipFrame(CGImageRef cover, CGSize size) {
    if (!cover) return NULL;
    CGContextRef context = newContext(size, NULL, 0);
    if (!context) return NULL;
    CGFloat width = CGImageGetWidth(cover), height = CGImageGetHeight(cover);
    CGFloat scale = MAX(size.width / MAX(width, 1), size.height / MAX(height, 1));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake((size.width - width * scale) / 2, (size.height - height * scale) / 2, width * scale, height * scale), cover);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat colors[] = {0, 0, 0, 0, 0, 0, 0, kShadeAlpha}, locations[] = {0, 1};
    CGGradientRef shade = CGGradientCreateWithColorComponents(space, colors, locations, 2);
    CGContextDrawLinearGradient(context, shade, CGPointMake(0, size.height * (1 - kShadeFrom)), CGPointZero, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(shade);
    CGColorSpaceRelease(space);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return frame;
}

BOOL SGCoverClipWrite(NSURL *file, CGImageRef cover, CGSize size) {
    CGImageRef frame = SGCoverClipFrame(cover, size);
    if (!frame) return NO;
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) {
        CGImageRelease(frame);
        return NO;
    }
    const int32_t fps = 2, seconds = 2;
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(1500000), AVVideoMaxKeyFrameIntervalKey: @(fps)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
        }];
    BOOL ok = [writer canAddInput:input];
    if (ok) {
        [writer addInput:input];
        ok = [writer startWriting];
    }
    if (ok) [writer startSessionAtSourceTime:kCMTimeZero];
    for (int32_t i = 0; i < fps * seconds && ok; i++) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
        CVPixelBufferRef buffer = NULL;
        ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
            && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
        if (!ok) break;
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = newContext(size, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        CGContextDrawImage(context, (CGRect){CGPointZero, size}, frame);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        ok = [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(i, fps)];
        CVPixelBufferRelease(buffer);
    }
    CGImageRelease(frame);
    if (!ok) {
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake(seconds, 1)];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) return NO;
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}
