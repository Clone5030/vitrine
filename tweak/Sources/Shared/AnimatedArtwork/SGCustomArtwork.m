// SGCustomArtwork.h says what this does.
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "SGCustomArtwork.h"

NSNotificationName const SGCustomArtworkDidChangeNotification = @"spotifyglass.customartwork.changed";

// A longer video is cut to its first seconds: the loop is made at full quality and played beside the player's own.
static const double kMostSeconds = 20, kLeastSeconds = 2, kBlendSeconds = 1;

static NSURL *folder(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [support URLByAppendingPathComponent:@"spotifyglass/customart" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

static NSURL *fileFor(NSString *uri) {
    NSData *data = [uri dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *name = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [name appendFormat:@"%02x", digest[i]];
    return [[folder() URLByAppendingPathComponent:name] URLByAppendingPathExtension:@"mp4"];
}

NSURL *SGCustomArtworkFor(NSString *uri) {
    if (!uri) return nil;
    NSURL *file = fileFor(uri);
    return [NSFileManager.defaultManager fileExistsAtPath:file.path] ? file : nil;
}

void SGCustomArtworkRemove(NSString *uri) {
    if (!uri) return;
    [NSFileManager.defaultManager removeItemAtURL:fileFor(uri) error:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:SGCustomArtworkDidChangeNotification object:nil];
}

#pragma mark - the loop

// `source` as a clip of its first seconds whose last second is blended into its first, so playing it round has no seam:
// the output at time t is the video at t + b, until the video's own end comes in, from the last b seconds on, under
// the video's start fading in over it. It ends on the video's b-second frame, which is the frame it starts on.
// Written to `out`; `done` gets nil, or what went wrong.
static void makeLoop(NSURL *source, NSURL *out, void (^done)(NSString *problem)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        AVAssetTrack *track = tracks.firstObject;
        if (!track) {
            done(@"That file has no video in it.");
            return;
        }
        double length = MIN(CMTimeGetSeconds(track.timeRange.duration), kMostSeconds);
        if (length < kLeastSeconds) {
            done(@"That video is too short to loop. Choose one of at least two seconds.");
            return;
        }
        double blend = MIN(kBlendSeconds, length / 4);
        CMTime b = CMTimeMakeWithSeconds(blend, 600), whole = CMTimeMakeWithSeconds(length, 600), total = CMTimeSubtract(whole, b);
        CMTime blendStart = CMTimeSubtract(total, b);

        AVMutableComposition *composition = [AVMutableComposition composition];
        AVMutableCompositionTrack *main = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        AVMutableCompositionTrack *start = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        NSError *failure = nil;
        BOOL ok = [main insertTimeRange:CMTimeRangeMake(b, total) ofTrack:track atTime:kCMTimeZero error:&failure]
               && [start insertTimeRange:CMTimeRangeMake(kCMTimeZero, b) ofTrack:track atTime:blendStart error:&failure];
        if (!ok) {
            done(@"That video could not be read.");
            return;
        }
        CGAffineTransform turn = track.preferredTransform;
        CGRect shown = CGRectApplyAffineTransform(CGRectMake(0, 0, track.naturalSize.width, track.naturalSize.height), turn);
        CGSize size = CGSizeMake(floor(fabs(shown.size.width) / 2) * 2, floor(fabs(shown.size.height) / 2) * 2);

        // The video's own picture is the lower layer where the two overlap, the start fading in over the end by the
        // end fading out: with the end on top, fading 1 to 0, and the start opaque under it.
        AVMutableVideoCompositionInstruction *plain = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        plain.timeRange = CMTimeRangeMake(kCMTimeZero, blendStart);
        AVMutableVideoCompositionLayerInstruction *mainOnly = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:main];
        [mainOnly setTransform:turn atTime:kCMTimeZero];
        plain.layerInstructions = @[mainOnly];

        AVMutableVideoCompositionInstruction *mixing = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        mixing.timeRange = CMTimeRangeMake(blendStart, b);
        AVMutableVideoCompositionLayerInstruction *fading = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:main];
        [fading setTransform:turn atTime:kCMTimeZero];
        [fading setOpacityRampFromStartOpacity:1 toEndOpacity:0 timeRange:mixing.timeRange];
        AVMutableVideoCompositionLayerInstruction *under = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:start];
        [under setTransform:turn atTime:kCMTimeZero];
        mixing.layerInstructions = @[fading, under];

        AVMutableVideoComposition *video = [AVMutableVideoComposition videoComposition];
        video.renderSize = size;
        video.frameDuration = CMTimeMake(1, 30);
        video.instructions = @[plain, mixing];

        NSURL *partial = [out URLByAppendingPathExtension:@"partial"];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        // H.264 in an MP4, which the lock screen takes; the 1080p preset keeps a phone video from being written larger.
        AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPreset1920x1080];
        if (!export) {
            done(@"This iPhone could not make the loop.");
            return;
        }
        export.videoComposition = video;
        export.outputFileType = AVFileTypeMPEG4;
        export.outputURL = partial;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [export exportAsynchronouslyWithCompletionHandler:^{
#pragma clang diagnostic pop
            if (export.status != AVAssetExportSessionStatusCompleted) {
                [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
                done(@"The loop could not be made from that video.");
                return;
            }
            [NSFileManager.defaultManager removeItemAtURL:out error:nil];
            done([NSFileManager.defaultManager moveItemAtURL:partial toURL:out error:nil] ? nil : @"The loop could not be saved.");
        }];
    }];
}

#pragma mark - choosing

@interface SGArtworkPicker : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) void (^working)(BOOL);
@end

static SGArtworkPicker *sg_picker;

static void tell(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

@implementation SGArtworkPicker

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSURL *picked = info[UIImagePickerControllerMediaURL];
    // The picked file is the picker's own and goes with it: copied before it is dismissed.
    NSURL *copy = nil;
    if (picked) {
        copy = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mov"]];
        if (![NSFileManager.defaultManager copyItemAtURL:picked toURL:copy error:nil]) copy = nil;
    }
    NSString *uri = self.uri;
    void (^working)(BOOL) = self.working;
    [picker dismissViewControllerAnimated:YES completion:^{
        sg_picker = nil;
        if (!copy) {
            if (working) working(NO);
            tell(@"Artwork not set", @"That video could not be opened.");
            return;
        }
        if (working) working(YES);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            makeLoop(copy, fileFor(uri), ^(NSString *problem) {
                [NSFileManager.defaultManager removeItemAtURL:copy error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (working) working(NO);
                    if (problem) {
                        tell(@"Artwork not set", problem);
                        return;
                    }
                    SGLog(@"custom artwork: a loop made for %@", uri);
                    [NSNotificationCenter.defaultCenter postNotificationName:SGCustomArtworkDidChangeNotification object:nil];
                });
            });
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    void (^working)(BOOL) = self.working;
    [picker dismissViewControllerAnimated:YES completion:^{
        sg_picker = nil;
        if (working) working(NO);
    }];
}

@end

void SGCustomArtworkChoose(NSString *uri, void (^working)(BOOL working)) {
    if (!uri || ![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) return;
    sg_picker = [SGArtworkPicker new];
    sg_picker.uri = uri;
    sg_picker.working = working;
    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[UTTypeMovie.identifier];
    picker.videoExportPreset = AVAssetExportPresetPassthrough;
    picker.delegate = sg_picker;
    picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}
